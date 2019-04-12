SHELL := /usr/bin/env bash

# Include project specific values file
# Requires the following variables:
# - CATALOG_NAMESPACE
# - DOCKERFILE
# - CHANNEL
# - IMAGE_REGISTRY
# - IMAGE_REPOSITORY
# - IMAGE_NAME
include project.mk
include functions.mk

# Validate variables in project.mk exist
ifndef CATALOG_NAMESPACE
$(error CATALOG_NAMESPACE is not set; check project.mk file)
endif
ifndef DOCKERFILE
$(error DOCKERFILE is not set; check project.mk file)
endif
ifndef CHANNEL
$(error CHANNEL is not set; check project.mk file)
endif
ifndef IMAGE_REGISTRY
$(error IMAGE_REGISTRY is not set; check project.mk file)
endif
ifndef IMAGE_REPOSITORY
$(error IMAGE_REPOSITORY is not set; check project.mk file)
endif
ifndef IMAGE_NAME
$(error IMAGE_NAME is not set; check project.mk file)
endif

# Generate version and tag information
CATALOG_HASH=$(shell find catalog-manifests/ -type f -exec openssl md5 {} \; | sort | openssl md5 | cut -d ' ' -f2)
CATALOG_VERSION=$(CHANNEL)-$(CATALOG_HASH)
GIT_TAG=release-$(CATALOG_VERSION)
CATALOG_IMAGE_URI=${IMAGE_REGISTRY}/${IMAGE_REPOSITORY}/${IMAGE_NAME}:${CATALOG_VERSION}

ALLOW_DIRTY_CHECKOUT?=false
SOURCE_DIR := operators

# List of github.org repositories containing operators
# This is in the format username/reponame separated by space:  user1/repo1 user2/repo2 user3/repo3
OPERATORS := openshift/dedicated-admin-operator

.PHONY: default
default: build

.PHONY: clean
clean:
	# clean checked out operator source
	rm -rf $(SOURCE_DIR)/
	# clean generated catalog
	git clean -df catalog-manifests/
	# revert packages and manifests/
	git checkout catalog-manifests/**/*.package.yaml manifests/

.PHONY: isclean
.SILENT: isclean
isclean:
	(test "$(ALLOW_DIRTY_CHECKOUT)" != "false" || test 0 -eq $$(git status --porcelain | wc -l)) || (echo "Local git checkout is not clean, commit changes and try again." && exit 1)

.PHONY: manifests/catalog
manifests/catalog: catalog
	mkdir -p manifests/
	# create CatalogSource yaml
	TEMPLATE=scripts/templates/catalog.yaml; \
	DEST=manifests/00-catalog.yaml; \
	$(call process_template,.,$$TEMPLATE,$$DEST)

# create yaml per operator
.PHONY: manifests/operators
manifests/operators: catalog
	mkdir -p manifests/ ;\
	for DIR in $(SOURCE_DIR)/**/ ; do \
		SOURCE_NAME=$$(echo $$DIR | cut -d/ -f2); \
		TEMPLATE=scripts/templates/operator.yaml; \
		DEST=manifests/10-$${SOURCE_NAME}.yaml; \
		$(call process_template,$$DIR,$$TEMPLATE,$$DEST); \
	done

.PHONY: manifests
manifests: manifests/catalog manifests/operators

.PHONY: operator-source
operator-source:
	for operator in $(OPERATORS); do \
		org="$$(echo $$operator | cut -d / -f 1)" ; \
		reponame="$$(echo $$operator | cut -d / -f 2-)" ; \
		echo "org = $$org reponame = $$reponame" ; \
		$(call checkout_operator,$$org,$$reponame) ;\
		echo ;\
	done

.PHONY: catalog
catalog: operator-source
	for DIR in $(SOURCE_DIR)/**/; do \
		eval $$($(MAKE) -C $$DIR env --no-print-directory); \
		./scripts/gen_operator_csv.py $$DIR $$OPERATOR_NAME $$OPERATOR_NAMESPACE $$OPERATOR_VERSION $$OPERATOR_IMAGE_URI $(CHANNEL) || (echo "Failed to generate, cleaning up catalog-manifests/$$OPERATOR_NAME/$$OPERATOR_VERSION" && rm -rf catalog-manifests/$$OPERATOR_NAME/$$OPERATOR_VERSION && exit 3); \
	done

.PHONY: check-operator-images
check-operator-images: operator-source
	for DIR in $(SOURCE_DIR)/**/; do \
		eval $$($(MAKE) -C $$DIR env --no-print-directory); \
		docker pull $$OPERATOR_IMAGE_URI || (echo "Image cannot be pulled: $$OPERATOR_IMAGE_URI" && exit 1); \
	done

.PHONY: build
build: isclean operator-source manifests catalog build-only

.PHONY: build-only
build-only:
	docker build -f ${DOCKERFILE} --tag $(CATALOG_IMAGE_URI) .

.PHONY: push
push: check-operator-images
	docker push $(CATALOG_IMAGE_URI)

.PHONY: git-commit
git-commit:
	git add catalog-manifests/ manifests/
	git commit -m "New catalog: $(CATALOG_VERSION)" --author="OpenShift SRE <aos-sre@redhat.com>"

.PHONY: git-tag
.SILENT: git-tag
git-tag:
	# attempt to tag, do not recreate a tag (only happens if changes happen outside of catalog-manifests/)
	git tag $(GIT_TAG) 2> /dev/null && echo "INFO: created tag: $(GIT_TAG)" || echo "INFO: git tag already exists, skipping tag creation: $(GIT_TAG)"

.PHONY: git-push
git-push: git-tag
	REMOTE=$(shell git status -sb | grep ^# | sed 's#.*[.]\([^./]*\)/[^./]*$$#\1#g'); \
	git push && git push $$REMOTE $(GIT_TAG)

.PHONY: version
version:
	@echo $(CATALOG_VERSION)
