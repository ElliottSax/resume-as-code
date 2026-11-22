# syntax=docker/dockerfile:1
#
# Two stages: a full Go toolchain compiles a static binary, then only that
# binary is copied onto a distroless base. The runtime image has no shell,
# no package manager and no libc, so there is very little to exploit or patch.
# Base images are pinned by digest. Dependabot proposes digest bumps as PRs,
# so an upstream change never reaches the image without passing the pipeline.

ARG GO_VERSION=1.27.4

FROM --platform=$BUILDPLATFORM golang:${GO_VERSION}-alpine@sha256:70bd7ddea8b6cbe5d6943cde279d6b67feb10cc924fb9100d1d8757c1575b280 AS build
WORKDIR /src

# Download modules in their own layer so code edits don't refetch them.
COPY app/go.mod app/go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download && go mod verify

COPY app/ ./

# Reject a malformed resume before anything is built. This runs natively on
# the build machine: the release binary below may be cross-compiled for
# another CPU (arm64 on an amd64 runner) and could not run here.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go run . validate

ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILD_DATE=unknown
ARG TARGETOS
ARG TARGETARCH
# CGO off gives a fully static binary; -trimpath drops local file paths;
# -s -w strips debug symbols. Together they make the build reproducible and small.
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags="-s -w \
      -X github.com/ElliottSax/resume-as-code/app/internal/buildinfo.Version=${VERSION} \
      -X github.com/ElliottSax/resume-as-code/app/internal/buildinfo.Commit=${COMMIT} \
      -X github.com/ElliottSax/resume-as-code/app/internal/buildinfo.Date=${BUILD_DATE}" \
      -o /out/resume .

FROM gcr.io/distroless/static-debian13:nonroot@sha256:aafe993665bf6200db38a02c11a9351e782a84b6a45e7f33b6695638c88e3931

LABEL org.opencontainers.image.title="resume-as-code" \
      org.opencontainers.image.description="A resume served by the production platform it describes" \
      org.opencontainers.image.source="https://github.com/ElliottSax/resume-as-code" \
      org.opencontainers.image.licenses="MIT"

COPY --from=build /out/resume /resume

# UID 65532 ("nonroot") is baked into the distroless base; Kubernetes
# enforces it again with runAsNonRoot.
USER 65532:65532
EXPOSE 8080 9090

# No shell in the image, so the binary probes itself.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["/resume", "healthcheck"]

ENTRYPOINT ["/resume"]
CMD ["serve"]
