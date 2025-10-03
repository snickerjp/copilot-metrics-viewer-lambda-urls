FROM ghcr.io/github-copilot-resources/copilot-metrics-viewer:latest

# Add Lambda Web Adapter
COPY --from=public.ecr.aws/awsguru/aws-lambda-adapter:0.8.4 /lambda-adapter /opt/extensions/lambda-adapter

ENV PORT=8080
ENV NITRO_PORT=8080
