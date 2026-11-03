FROM node:24-alpine

ENV NODE_ENV=production
# The container is run without compose, so the scheduler is enabled here.
ENV EXPIRY_SCHEDULER_ENABLED=true
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts

COPY server.js expiry_scheduler.js ./
USER node
EXPOSE 3001
CMD ["node", "server.js"]