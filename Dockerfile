FROM haproxy:2.7
USER root
RUN apt-get update && apt-get install -y socat
USER haproxy
