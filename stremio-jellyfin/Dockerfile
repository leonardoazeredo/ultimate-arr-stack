FROM node:21-slim

# Defaults only, and the literal string "changeme" is the point: no credential
# is baked into this image. The compose service always sets the real values
# (`JELLYFIN_PASSWORD=${STREMIO_JELLYFIN_PASSWORD}`, from the host's .env), so
# these lines describe a container that has not been configured rather than one
# that has. Trivy's DS-0031 flags the ENV line for looking like a secret; the
# scan reads the variable name, not the value, and the value here is inert.
ENV JELLYFIN_USER "changeme"
ENV JELLYFIN_PASSWORD "changeme"
ENV SERVER_PORT 60421
ENV JELLYFIN_SERVER "http://localhost"

RUN mkdir -p /home/node/app/node_modules && chown -R node:node /home/node/app
WORKDIR /home/node/app

COPY package*.json ./
COPY *.js ./

RUN chown -R node:node /home/node/app

USER node
# package-lock.json is gitignored (.gitignore:95), so this resolves against
# package.json on every build by design -- the lockfile that would pin it is not
# in the repository. The base image is pinned; see CONTRIBUTING.md, "Image
# pinning".
RUN npm install

EXPOSE $SERVER_PORT
ENTRYPOINT ["node", "server.js"]
