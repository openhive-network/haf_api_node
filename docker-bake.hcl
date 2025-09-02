variable "CI_REGISTRY_IMAGE" {
    default = "registry.gitlab.syncad.com/hive/haf_api_node"
}
variable TAG {
    default = "latest"
}
variable "CI_COMMIT_TAG" {
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
  targets = ["compose-ci", "dind-ci", "haproxy-healthchecks-ci", "haproxy-ci"]
}

# All images that need to be published to blog registry on release
group "release-images" {
  targets = ["haproxy-healthchecks-release", "haproxy-release"]
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