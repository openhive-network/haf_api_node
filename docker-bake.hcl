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

group "ci" {
  targets = ["compose-ci", "dind-ci"]
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