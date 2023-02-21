FROM node:18-alpine AS builder
RUN apk add --no-cache libc6-compat
RUN apk update
# Set working directory
WORKDIR /app

RUN yarn global add turbo
COPY . .

RUN turbo prune --scope=app --docker

# Add lockfile and package.json's of isolated subworkspace
FROM node:18-alpine AS installer


RUN apk add --no-cache libc6-compat
RUN apk update
WORKDIR /app

# First install the dependencies (as they change less often)
COPY .gitignore .gitignore
COPY --from=builder /app/out/json/ .
COPY --from=builder /app/out/yarn.lock ./yarn.lock
RUN yarn install

# Build the project
COPY --from=builder /app/out/full/ .
COPY turbo.json turbo.json

RUN yarn turbo run build --filter=app


FROM python:3.11.1-alpine3.17 AS backend

# set environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV PIP_DISABLE_PIP_VERSION_CHECK=1 

WORKDIR /code

RUN apk --update --no-cache add \
    "libpq~=15" \
    "libxslt~=1.1" \
    "nodejs-current~=19" \
    "xmlsec~=1.2" \
    "nginx" \
    "nodejs" \
    "npm" \
    "supervisor"

COPY apiserver/requirements.txt ./
COPY apiserver/requirements ./requirements
RUN apk add libffi-dev
RUN apk --update --no-cache --virtual .build-deps add \
    "bash~=5.2" \
    "g++~=12.2" \
    "gcc~=12.2" \
    "cargo~=1.64" \
    "git~=2" \
    "make~=4.3" \
    "postgresql13-dev~=13" \
    "libc-dev" \
    "linux-headers" \
    && \
    pip install -r requirements.txt --compile --no-cache-dir \
    && \
    apk del .build-deps

# Add in Django deps and generate Django's static files
COPY apiserver/manage.py manage.py
COPY apiserver/plane plane/
COPY apiserver/templates templates/

COPY apiserver/gunicorn.config.py ./
RUN apk --update --no-cache add "bash~=5.2"
COPY apiserver/bin ./bin/

RUN chmod +x ./bin/takeoff ./bin/worker
RUN chmod -R 777 /code

# Expose container port and run entry point script
EXPOSE 8000
EXPOSE 3000
EXPOSE 80



WORKDIR /app

# Don't run production as root
RUN addgroup --system --gid 1001 plane
RUN adduser --system --uid 1001 captain

COPY --from=installer /app/apps/app/next.config.js .
COPY --from=installer /app/apps/app/package.json .

COPY --from=installer --chown=captain:plane /app/apps/app/.next/standalone ./

COPY --from=installer --chown=captain:plane /app/apps/app/.next/static ./apps/app/.next/static

ENV NEXT_TELEMETRY_DISABLED 1

# RUN rm /etc/nginx/conf.d/default.conf
#######################################################################
COPY nginx/nginx-single-docker-image.conf /etc/nginx/http.d/default.conf
#######################################################################

COPY nginx/supervisor.conf /code/supervisor.conf


CMD ["supervisord","-c","/code/supervisor.conf"]




