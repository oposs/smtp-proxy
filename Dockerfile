FROM alpine:3.15 AS build-env
ARG V
RUN apk update && \
    apk upgrade && \
    apk --no-cache add \
        build-base \
        patch \
        wget \
        openssl-dev \
        openssl \
        perl-dev \
        zlib-dev
COPY smtp-proxy-${V}.tar.gz /
RUN tar -xzf smtp-proxy-${V}.tar.gz && \
    cd smtp-proxy-${V} && \
    ./configure --prefix=/app && \
    make
RUN cd smtp-proxy-${V} && \
    make install

FROM alpine:3.15
RUN apk update && \
    apk upgrade && \
    apk --no-cache add \
    perl \
    curl \
    libssl1.1 \
    openssl
EXPOSE 3000/tcp
COPY --from=build-env /app /app
RUN perl -c /app/bin/smtpproxy.pl
ENV MOJO_LOG_LEVEL=trace
ENV MOJO_MODE=production
ENV MOJO_CLIENT_DEBUG=0
ENV MOJO_SERVER_DEBUG=0
ENTRYPOINT ["/app/bin/smtpproxy.pl"]