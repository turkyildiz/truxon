# Vision-enrich image: Playwright (Chromium, for signed-PDF fetch) + poppler
# (pdftoppm, to rasterize rate cons) baked in, so no apt install runs per job
# inside a container that touches prod data — M-7. Built once on the NAS:
#   docker build -t truxon-vision /volume1/docker/truxon-vision
# Then run-vision.sh / vision-loop.sh pick it up via VISION_IMAGE=truxon-vision.
# Base is already digest-pinned by Playwright's release tag.
FROM mcr.microsoft.com/playwright:v1.61.1-jammy
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends poppler-utils \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
