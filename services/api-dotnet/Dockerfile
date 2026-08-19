# syntax=docker/dockerfile:1
#
# Both stages pinned by digest. The runtime stage is Microsoft's chiseled image —
# their distroless equivalent: no shell, no package manager, non-root by default.

# mcr.microsoft.com/dotnet/sdk:10.0
FROM mcr.microsoft.com/dotnet/sdk@sha256:e1ffd2a92ae84c1291bc1b6887501f8af98e6331e7af6d4c8d37168c5e87a64c AS builder

WORKDIR /build

COPY src/ApiDotnet.csproj ./src/
RUN dotnet restore ./src/ApiDotnet.csproj

COPY src ./src
RUN dotnet publish ./src/ApiDotnet.csproj -c Release -o /app --no-restore

# mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled
FROM mcr.microsoft.com/dotnet/aspnet@sha256:0839314d08bb65da369135389a5d8291f75ace587fbb0488f469eb92c62eef68

ARG SOURCE_URL="https://github.com/justinepdevasia/secure-delivery-pipeline"
ARG REVISION="unknown"
ARG CREATED="1970-01-01T00:00:00Z"

LABEL org.opencontainers.image.title="api-dotnet" \
      org.opencontainers.image.description="Second-runtime demo API for the secure-delivery-pipeline" \
      org.opencontainers.image.source="${SOURCE_URL}" \
      org.opencontainers.image.revision="${REVISION}" \
      org.opencontainers.image.created="${CREATED}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled"

WORKDIR /app
COPY --from=builder /app .

ENV ASPNETCORE_URLS=http://+:8000 \
    DOTNET_EnableDiagnostics=0

# $APP_UID in the chiseled images is 1654; stated numerically so the guarantee
# survives a base image change.
USER 1654:1654

EXPOSE 8000

ENTRYPOINT ["dotnet", "ApiDotnet.dll"]
