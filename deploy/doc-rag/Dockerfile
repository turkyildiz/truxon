# Indexer image: node + pdftotext (poppler). Built once on the NAS:
#   docker build -t truxon-rag-node /volume1/docker/truxon-rag
# run-index.sh uses this; the search worker needs no pdftotext and stays
# on plain node:20-slim.
FROM node:20-slim
RUN apt-get update && apt-get install -y --no-install-recommends poppler-utils \
    && rm -rf /var/lib/apt/lists/*
