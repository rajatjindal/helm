BINDIR      := $(CURDIR)/bin
DIST_DIRS   := find * -type d -exec
TARGETS     := darwin/amd64 linux/amd64 linux/386 linux/arm linux/arm64 linux/ppc64le linux/s390x windows/amd64
TARGET_OBJS ?= darwin-amd64.tar.gz darwin-amd64.tar.gz.sha256 darwin-amd64.tar.gz.sha256sum linux-amd64.tar.gz linux-amd64.tar.gz.sha256 linux-amd64.tar.gz.sha256sum linux-386.tar.gz linux-386.tar.gz.sha256 linux-386.tar.gz.sha256sum linux-arm.tar.gz linux-arm.tar.gz.sha256 linux-arm.tar.gz.sha256sum linux-arm64.tar.gz linux-arm64.tar.gz.sha256 linux-arm64.tar.gz.sha256sum linux-ppc64le.tar.gz linux-ppc64le.tar.gz.sha256 linux-ppc64le.tar.gz.sha256sum linux-s390x.tar.gz linux-s390x.tar.gz.sha256 linux-s390x.tar.gz.sha256sum windows-amd64.zip windows-amd64.zip.sha256 windows-amd64.zip.sha256sum
BINNAME     ?= helm

GOPATH        = $(shell go env GOPATH)
GOX           = $(GOPATH)/bin/gox
GOIMPORTS     = $(GOPATH)/bin/goimports
ARCH          = $(shell uname -p)

ACCEPTANCE_DIR:=../acceptance-testing
# To specify the subset of acceptance tests to run. '.' means all tests
ACCEPTANCE_RUN_TESTS=.

# go option
PKG        := ./...
TAGS       :=
TESTS      := .
TESTFLAGS  :=
LDFLAGS    := -w -s
GOFLAGS    :=
SRC        := $(shell find . -type f -name '*.go' -print)

# Required for globs to work correctly
SHELL      = /usr/bin/env bash

GIT_COMMIT = $(shell git rev-parse HEAD)
GIT_SHA    = $(shell git rev-parse --short HEAD)
GIT_TAG    = $(shell git describe --tags --abbrev=0 --exact-match 2>/dev/null)
GIT_DIRTY  = $(shell test -n "`git status --porcelain`" && echo "dirty" || echo "clean")

ifdef VERSION
	BINARY_VERSION = $(VERSION)
endif
BINARY_VERSION ?= ${GIT_TAG}

# Only set Version if building a tag or VERSION is set
ifneq ($(BINARY_VERSION),)
	LDFLAGS += -X helm.sh/helm/v3/internal/version.version=${BINARY_VERSION}
endif

VERSION_METADATA = unreleased
# Clear the "unreleased" string in BuildMetadata
ifneq ($(GIT_TAG),)
	VERSION_METADATA =
endif

LDFLAGS += -X helm.sh/helm/v3/internal/version.metadata=${VERSION_METADATA}
LDFLAGS += -X helm.sh/helm/v3/internal/version.gitCommit=${GIT_COMMIT}
LDFLAGS += -X helm.sh/helm/v3/internal/version.gitTreeState=${GIT_DIRTY}

.PHONY: all
all: build

# ------------------------------------------------------------------------------
#  build

.PHONY: build
build: $(BINDIR)/$(BINNAME)

$(BINDIR)/$(BINNAME): $(SRC)
	GO111MODULE=on go build $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' -o $(BINDIR)/$(BINNAME) ./cmd/helm

# ------------------------------------------------------------------------------
#  test

.PHONY: test
test: build
ifeq ($(ARCH),s390x)
test: TESTFLAGS += -v
else
test: TESTFLAGS += -race -v
endif
test: test-style
test: test-unit

.PHONY: test-unit
test-unit:
	@echo
	@echo "==> Running unit tests <=="
	GO111MODULE=on go test $(GOFLAGS) -run $(TESTS) $(PKG) $(TESTFLAGS)

.PHONY: test-coverage
test-coverage:
	@echo
	@echo "==> Running unit tests with coverage <=="
	@ ./scripts/coverage.sh

.PHONY: test-style
test-style:
	GO111MODULE=on golangci-lint run
	@scripts/validate-license.sh

.PHONY: test-acceptance
test-acceptance: TARGETS = linux/amd64
test-acceptance: build build-cross
	@if [ -d "${ACCEPTANCE_DIR}" ]; then \
		cd ${ACCEPTANCE_DIR} && \
			ROBOT_RUN_TESTS=$(ACCEPTANCE_RUN_TESTS) ROBOT_HELM_PATH=$(BINDIR) make acceptance; \
	else \
		echo "You must clone the acceptance_testing repo under $(ACCEPTANCE_DIR)"; \
		echo "You can find the acceptance_testing repo at https://github.com/helm/acceptance-testing"; \
	fi

.PHONY: test-acceptance-completion
test-acceptance-completion: ACCEPTANCE_RUN_TESTS = shells.robot
test-acceptance-completion: test-acceptance

.PHONY: coverage
coverage:
	@scripts/coverage.sh

.PHONY: format
format: $(GOIMPORTS)
	GO111MODULE=on go list -f '{{.Dir}}' ./... | xargs $(GOIMPORTS) -w -local helm.sh/helm

# ------------------------------------------------------------------------------
#  dependencies

# If go get is run from inside the project directory it will add the dependencies
# to the go.mod file. To avoid that we change to a directory without a go.mod file
# when downloading the following dependencies

$(GOX):
	(cd /; GO111MODULE=on go get -u github.com/mitchellh/gox)

$(GOIMPORTS):
	(cd /; GO111MODULE=on go get -u golang.org/x/tools/cmd/goimports)

# ------------------------------------------------------------------------------
#  release

.PHONY: build-cross
build-cross: LDFLAGS += -extldflags "-static"
build-cross: $(GOX)
	GO111MODULE=on CGO_ENABLED=0 $(GOX) -parallel=3 -output="_dist/{{.OS}}-{{.Arch}}/$(BINNAME)" -osarch='$(TARGETS)' $(GOFLAGS) -tags '$(TAGS)' -ldflags '$(LDFLAGS)' ./cmd/helm

.PHONY: dist
dist:
	( \
		cd _dist && \
		$(DIST_DIRS) cp ../LICENSE {} \; && \
		$(DIST_DIRS) cp ../README.md {} \; && \
		$(DIST_DIRS) tar -zcf helm-${VERSION}-{}.tar.gz {} \; && \
		$(DIST_DIRS) zip -r helm-${VERSION}-{}.zip {} \; \
	)

.PHONY: fetch-dist
fetch-dist:
	mkdir -p _dist
	cd _dist && \
	for obj in ${TARGET_OBJS} ; do \
		curl -sSL -o helm-${VERSION}-$${obj} https://get.helm.sh/helm-${VERSION}-$${obj} ; \
	done

.PHONY: sign
sign:
	for f in _dist/*.{gz,zip,sha256,sha256sum} ; do \
		gpg --armor --detach-sign $${f} ; \
	done

# The contents of the .sha256sum file are compatible with tools like
# shasum. For example, using the following command will verify
# the file helm-3.1.0-rc.1-darwin-amd64.tar.gz:
#   shasum -a 256 -c helm-3.1.0-rc.1-darwin-amd64.tar.gz.sha256sum
# The .sha256 files hold only the hash and are not compatible with
# verification tools like shasum or sha256sum. This method and file can be
# removed in Helm v4.
.PHONY: checksum
checksum:
	for f in _dist/*.{gz,zip} ; do \
		shasum -a 256 "$${f}" | sed 's/_dist\///' > "$${f}.sha256sum" ; \
		shasum -a 256 "$${f}" | awk '{print $$1}' > "$${f}.sha256" ; \
	done

# ------------------------------------------------------------------------------

.PHONY: clean
clean:
	@rm -rf $(BINDIR) ./_dist

.PHONY: release-notes
release-notes:
		@if [ ! -d "./_dist" ]; then \
			echo "please run 'make fetch-dist' first" && \
			exit 1; \
		fi
		@if [ -z "${PREVIOUS_RELEASE}" ]; then \
			echo "please set PREVIOUS_RELEASE environment variable" \
			&& exit 1; \
		fi

		@./scripts/release-notes.sh ${PREVIOUS_RELEASE} ${VERSION}



.PHONY: info
info:
	 @echo "Version:           ${VERSION}"
	 @echo "Git Tag:           ${GIT_TAG}"
	 @echo "Git Commit:        ${GIT_COMMIT}"
	 @echo "Git Tree State:    ${GIT_DIRTY}"
