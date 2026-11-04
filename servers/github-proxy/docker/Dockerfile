FROM python:3.14-alpine
COPY github_proxy/ /app/github_proxy/
WORKDIR /app
CMD ["python3", "-m", "github_proxy.server"]
