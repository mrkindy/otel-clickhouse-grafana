IMAGE      ?= otel-clickhouse-grafana
TAG        ?= dev
PLATFORMS  ?= linux/amd64,linux/arm64
VERSION    ?= 0.1.0
BUILDER    ?= octg-multiarch

.PHONY: build test run dashboards push

build: ## Build for the local architecture
	docker build -t $(IMAGE):$(TAG) .

test: build ## Build, then run the end-to-end smoke test
	IMAGE=$(IMAGE):$(TAG) test/smoke.sh

run: ## Run locally in plain-HTTP mode on http://localhost:8080
	docker run --rm -it -p 8080:80 -v octg-data:/data $(IMAGE):$(TAG)

dashboards: ## Regenerate the Grafana dashboard JSON
	python3 dashboards/build.py

push: ## Multi-arch build and push: make push IMAGE=<user>/otel-clickhouse-grafana VERSION=x.y.z
	docker buildx inspect $(BUILDER) >/dev/null 2>&1 || docker buildx create --name $(BUILDER) --driver docker-container
	docker buildx build --builder $(BUILDER) --platform $(PLATFORMS) \
	  -t $(IMAGE):$(VERSION) -t $(IMAGE):$(basename $(VERSION)) -t $(IMAGE):latest --push .
