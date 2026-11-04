FROM python:3.14-alpine
COPY tasks_server/ /app/tasks_server/
COPY ui/ /app/ui/
WORKDIR /app
CMD ["python3", "-m", "tasks_server.server"]
