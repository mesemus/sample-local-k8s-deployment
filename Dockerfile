ARG OAREPO_DEVELOPMENT_IMAGE=oarepo/oarepo-base-development:14
ARG OAREPO_PRODUCTION_IMAGE=oarepo/oarepo-base-production:14
ARG BUILDPLATFORM=linux/amd64
ARG DEPLOYMENT_VERSION

FROM --platform=$BUILDPLATFORM ${OAREPO_DEVELOPMENT_IMAGE} AS production-build

ENV INVENIO_INSTANCE_PATH=/opt/invenio/var/instance
ENV UV_LOCKED=true
ENV UV_PROJECT_ENVIRONMENT=/opt/invenio/src/.venv
ENV WORKING_DIR=/opt/invenio/src
ENV FLASK_DEBUG=False
ENV INVENIO_COLLECT_STORAGE="flask_collect.storage.file"
ENV UV_EXTRA_INDEX_URL=https://gitlab.cesnet.cz/api/v4/projects/1408/packages/pypi/simple
# Allow resolution & installation of RDM packages with pre-release versioning, e.g: `invenio-app-rdm==14.0.0.68614b0.dev3`
ENV UV_PRERELEASE=allow
ENV PIP_EXTRA_INDEX_URL=https://gitlab.cesnet.cz/api/v4/projects/1408/packages/pypi/simple

# TODO: just a placeholder for build - overriden by deployment env, move to repo variables?
ENV INVENIO_EINFRA_CONSUMER_KEY=changeme
ENV INVENIO_EINFRA_CONSUMER_SECRET=changeme

RUN mkdir -p ${INVENIO_INSTANCE_PATH} && \
    mkdir \
        ${INVENIO_INSTANCE_PATH}/data \
        ${INVENIO_INSTANCE_PATH}/archive \
        ${INVENIO_INSTANCE_PATH}/static

# copy repository code
COPY .. ${WORKING_DIR}

# /repository is the old WORKING_DIR location; kept as a symlink for anything
# outside this Dockerfile that still expects it there
RUN ln -s ${WORKING_DIR} /repository

# install dependencies from uv lock file
WORKDIR ${WORKING_DIR}
RUN rm -rf .nrp .venv .tools

RUN pwd
RUN ls -la
RUN test -f uv.lock || (echo "uv.lock file not found!" && uv lock -v)

RUN if [ -f .npmrc ] ; then echo "Using custom provided .npmrc, copying to ~";  cp .npmrc ~/.npmrc; ls -la ~; fi

RUN ls -lR .

RUN ./run.sh install

# compile translations. Normally this is done in invenio-cli services setup,
# but we need it done at build time for production image as it can be a part of,
# for example, upgrade process where services setup is not run.
RUN ./run.sh translations compile

# cleanup
# (.venv is no longer removed here: WORKING_DIR and UV_PROJECT_ENVIRONMENT
# now share the same /opt/invenio/src root, so .venv here is the real venv.
# Same reason .venv is pruned from the __pycache__ cleanup below: it now
# lives inside WORKING_DIR, and wiping its bytecode cache forces every pod
# to recompile the entire dependency tree on first import.)
RUN rm -rf .nrp .pdm-build
RUN find . -path ./.venv -prune -o -name "__pycache__" -type d -exec rm -rf {} +

RUN cp ${WORKING_DIR}/variables ${INVENIO_INSTANCE_PATH}/variables

RUN cp -r ./static/. ${INVENIO_INSTANCE_PATH}/static/


FROM --platform=$BUILDPLATFORM ${OAREPO_PRODUCTION_IMAGE} AS production

ARG REPOSITORY_SITE_ORGANIZATION
ARG REPOSITORY_SITE_NAME
ARG REPOSITORY_IMAGE_URL
ARG REPOSITORY_AUTHOR
ARG REPOSITORY_GITHUB_URL
ARG REPOSITORY_URL
ARG REPOSITORY_DOCUMENTATION
ARG DEPLOYMENT_VERSION

LABEL maintainer="${REPOSITORY_SITE_ORGANIZATION}" \
    org.opencontainers.image.authors="${REPOSITORY_AUTHOR}" \
    org.opencontainers.image.title="NR Docs production image" \
    org.opencontainers.image.url="${REPOSITORY_IMAGE_URL}" \
    org.opencontainers.image.source="${REPOSITORY_GITHUB_URL}" \
    org.opencontainers.image.documentation="${REPOSITORY_DOCUMENTATION}"

ENV DEPLOYMENT_VERSION=${DEPLOYMENT_VERSION}
ENV INVENIO_DEPLOYMENT_VERSION=${DEPLOYMENT_VERSION}
ENV WORKING_DIR=/opt/invenio/src
ENV UV_PROJECT_ENVIRONMENT=/opt/invenio/src/.venv
# Must match the production-build stage's INVENIO_INSTANCE_PATH, and the
# upstream Invenio/Helm-chart convention (/opt/invenio/var/instance).
ENV INVENIO_INSTANCE_PATH=/opt/invenio/var/instance

# copy build from production build - just the final directories, not the whole build
# (venv, source, and instance path all live under /opt/invenio)

COPY --from=production-build /opt/invenio /opt/invenio

# /repository is the old WORKING_DIR location; kept as a symlink for anything
# outside this Dockerfile that still expects it there
RUN ln -s ${WORKING_DIR} /repository

# copy uwsgi.ini - keep the path the same as in invenio
RUN mkdir -p /opt/invenio/src/uwsgi/

# TODO(mesemus): consider if this is really needed by production profile
# in reality, this would be overriden by the uwsgi.ini k8s config map
#
#COPY ./docker/development.crt /development.crt
#COPY ./docker/development.key /development.key
#
#COPY ./docker/production/uwsgi.ini /opt/invenio/src/uwsgi/uwsgi.ini

ENV PATH=/opt/invenio/src/.venv/bin:${PATH}

RUN ls -la /opt/invenio/src/.venv/bin

RUN uv pip install --no-cache-dir uwsgi uwsgi-tools
RUN uv pip install --no-cache-dir git+https://github.com/oarepo/invenio-cli@oarepo-feature-docker-environment

# Set folder permissions
RUN chmod -R g=u ${WORKING_DIR} && \
    chown -R invenio:root ${WORKING_DIR}

RUN ( echo "Contents of ${WORKING_DIR}"; ls -lR ${WORKING_DIR})
RUN ( echo "Contents of /opt/invenio"; ls -lR /opt/invenio )

ENTRYPOINT [ "sh", "-c" ]
