FROM python:3.14-alpine
COPY llm_proxy/ /app/llm_proxy/
WORKDIR /app
CMD ["python3", "-m", "llm_proxy.server"]
