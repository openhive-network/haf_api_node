variable "CI_REGISTRY_IMAGE" {
    default = "registry.gitlab.syncad.com/hive/haf_api_node"
}
variable "TAG" {
    default = "latest"
}
variable "CI_COMMIT_TAG" {
  default = ""
}
variable "BUILD_TIME" {
  default = ""
}
variable "GIT_COMMIT_SHA" {
  default = ""
}
variable "GIT_CURRENT_BRANCH" {
  default = ""
}
variable "GIT_LAST_LOG_MESSAGE" {
  default = ""
}
variable "GIT_LAST_COMMITTER" {
  default = ""
}
variable "GIT_LAST_COMMIT_DATE" {
  default = ""
}

function "notempty" {
  params = [variable]
  result = notequal("", variable)
}

function "registry-name" {
  params = [name, suffix]
  result = notempty(suffix) ? "${CI_REGISTRY_IMAGE}/${name}/${suffix}" : "${CI_REGISTRY_IMAGE}/${name}"
}

group "default" {
  targets = ["compose", "dind"]
}

# CI infrastructure images (used for running tests)
group "ci-infrastructure" {
  targets = ["compose-ci", "dind-ci"]
}

# All images that need to be built and pushed on every pipeline
group "pipeline-images" {
  targets = ["compose-ci", "dind-ci", "haproxy-healthchecks-ci", "haproxy-ci", "caddy-ci", "postgrest-ci", "swagger-ci", "version-display-ci"]
}

# All images that need to be published to blog registry on release
group "release-images" {
  targets = ["haproxy-healthchecks-release", "haproxy-release", "caddy-release", "postgrest-release", "swagger-release", "version-display-release"]
}

# All images that need to be tagged as develop when on develop branch
group "develop-images" {
  targets = ["haproxy-healthchecks-develop", "haproxy-develop", "caddy-develop", "postgrest-develop", "swagger-develop", "version-display-develop"]
}

target "compose" {
  dockerfile = "ci/compose/Dockerfile"
  tags = [
    "${registry-name("compose", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("compose", "")}:${CI_COMMIT_TAG}": ""
  ]
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "${registry-name("compose", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "dind" {
  dockerfile = "ci/dind/Dockerfile"
  tags = [
    "${registry-name("dind", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("dind", "")}:${CI_COMMIT_TAG}": "",
  ]
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "type=registry,ref=${registry-name("dind", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "compose-ci" {
  inherits = ["compose"]
  output = [
    "type=registry"
  ]
}

target "dind-ci" {
  inherits = ["dind"]
  output = [
    "type=registry"
  ]
}

target "haproxy" {
  dockerfile = "Dockerfile"
  context = "haproxy"
  tags = [
    "${registry-name("haproxy", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("haproxy", "")}:${CI_COMMIT_TAG}": ""
  ]
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "${registry-name("haproxy", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "haproxy-healthchecks" {
  dockerfile = "Dockerfile"
  context = "healthchecks"
  tags = [
    "${registry-name("haproxy-healthchecks", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("haproxy-healthchecks", "")}:${CI_COMMIT_TAG}": ""
  ]
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "${registry-name("haproxy-healthchecks", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "haproxy-ci" {
  inherits = ["haproxy"]
  output = [
    "type=registry"
  ]
}

target "haproxy-healthchecks-ci" {
  inherits = ["haproxy-healthchecks"]
  output = [
    "type=registry"
  ]
}

# Caddy image
target "caddy" {
  dockerfile = "Dockerfile"
  context = "caddy"
  tags = [
    "${registry-name("caddy", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("caddy", "")}:${CI_COMMIT_TAG}": ""
  ]
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "${registry-name("caddy", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "caddy-ci" {
  inherits = ["caddy"]
  output = [
    "type=registry"
  ]
}

# PostgREST image
target "postgrest" {
  dockerfile = "Dockerfile"
  context = "postgrest"
  tags = [
    "${registry-name("postgrest", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("postgrest", "")}:${CI_COMMIT_TAG}": ""
  ]
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "${registry-name("postgrest", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "postgrest-ci" {
  inherits = ["postgrest"]
  output = [
    "type=registry"
  ]
}

# Swagger image
target "swagger" {
  dockerfile = "Dockerfile"
  context = "swagger"
  tags = [
    "${registry-name("swagger", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("swagger", "")}:${CI_COMMIT_TAG}": ""
  ]
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "${registry-name("swagger", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "swagger-ci" {
  inherits = ["swagger"]
  output = [
    "type=registry"
  ]
}

# Version display image
target "version-display" {
  dockerfile = "Dockerfile"
  context = "version-display"
  tags = [
    "${registry-name("version-display", "")}:${TAG}",
    notempty(CI_COMMIT_TAG) ? "${registry-name("version-display", "")}:${CI_COMMIT_TAG}": ""
  ]
  args = {
    BUILD_TIME = "${BUILD_TIME}"
    GIT_COMMIT_SHA = "${GIT_COMMIT_SHA}"
    GIT_CURRENT_BRANCH = "${GIT_CURRENT_BRANCH}"
    GIT_LAST_LOG_MESSAGE = "${GIT_LAST_LOG_MESSAGE}"
    GIT_LAST_COMMITTER = "${GIT_LAST_COMMITTER}"
    GIT_LAST_COMMIT_DATE = "${GIT_LAST_COMMIT_DATE}"
  }
  cache-to = [
    "type=inline"
  ]
  cache-from = [
    "${registry-name("version-display", "")}:${TAG}",
  ]
  platforms = [
    "linux/amd64"
  ]
  output = [
    "type=docker"
  ]
}

target "version-display-ci" {
  inherits = ["version-display"]
  output = [
    "type=registry"
  ]
}

# Special targets for publishing to blog registry on releases
target "haproxy-release" {
  inherits = ["haproxy"]
  tags = [
    "${registry-name("haproxy", "")}:${CI_COMMIT_TAG}",
    "registry-upload.hive.blog/haf_api_node/haproxy:${CI_COMMIT_TAG}"
  ]
  output = [
    "type=registry"
  ]
}

target "haproxy-healthchecks-release" {
  inherits = ["haproxy-healthchecks"]
  tags = [
    "${registry-name("haproxy-healthchecks", "")}:${CI_COMMIT_TAG}",
    "registry-upload.hive.blog/haf_api_node/haproxy-healthchecks:${CI_COMMIT_TAG}"
  ]
  output = [
    "type=registry"
  ]
}

target "caddy-release" {
  inherits = ["caddy"]
  tags = [
    "${registry-name("caddy", "")}:${CI_COMMIT_TAG}",
    "registry-upload.hive.blog/haf_api_node/caddy:${CI_COMMIT_TAG}"
  ]
  output = [
    "type=registry"
  ]
}

target "postgrest-release" {
  inherits = ["postgrest"]
  tags = [
    "${registry-name("postgrest", "")}:${CI_COMMIT_TAG}",
    "registry-upload.hive.blog/haf_api_node/postgrest:${CI_COMMIT_TAG}"
  ]
  output = [
    "type=registry"
  ]
}

target "swagger-release" {
  inherits = ["swagger"]
  tags = [
    "${registry-name("swagger", "")}:${CI_COMMIT_TAG}",
    "registry-upload.hive.blog/haf_api_node/swagger:${CI_COMMIT_TAG}"
  ]
  output = [
    "type=registry"
  ]
}

target "version-display-release" {
  inherits = ["version-display"]
  tags = [
    "${registry-name("version-display", "")}:${CI_COMMIT_TAG}",
    "registry-upload.hive.blog/haf_api_node/version-display:${CI_COMMIT_TAG}"
  ]
  output = [
    "type=registry"
  ]
}

# Develop branch targets
target "haproxy-develop" {
  inherits = ["haproxy"]
  tags = [
    "${registry-name("haproxy", "")}:develop"
  ]
  output = [
    "type=registry"
  ]
}

target "haproxy-healthchecks-develop" {
  inherits = ["haproxy-healthchecks"]
  tags = [
    "${registry-name("haproxy-healthchecks", "")}:develop"
  ]
  output = [
    "type=registry"
  ]
}

target "caddy-develop" {
  inherits = ["caddy"]
  tags = [
    "${registry-name("caddy", "")}:develop"
  ]
  output = [
    "type=registry"
  ]
}

target "postgrest-develop" {
  inherits = ["postgrest"]
  tags = [
    "${registry-name("postgrest", "")}:develop"
  ]
  output = [
    "type=registry"
  ]
}

target "swagger-develop" {
  inherits = ["swagger"]
  tags = [
    "${registry-name("swagger", "")}:develop"
  ]
  output = [
    "type=registry"
  ]
}

target "version-display-develop" {
  inherits = ["version-display"]
  tags = [
    "${registry-name("version-display", "")}:develop"
  ]
  output = [
    "type=registry"
  ]
}