# Base off the standard swagger-ui image
FROM swaggerapi/swagger-ui:latest

ARG DOCKER_GEN_VERSION=0.14.7
RUN wget -O - https://github.com/nginx-proxy/docker-gen/releases/download/${DOCKER_GEN_VERSION}/docker-gen-alpine-linux-amd64-${DOCKER_GEN_VERSION}.tar.gz | tar -C /usr/local/bin -xzf -

# Copy in our template + entrypoint
COPY templates/swagger.tmpl /etc/docker-gen/templates/swagger.tmpl
COPY entrypoint.sh           /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Override startup
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
