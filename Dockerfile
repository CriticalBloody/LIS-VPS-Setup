FROM python:3.11-alpine

WORKDIR /app

COPY agent.py /app/agent.py

ENV PYTHONUNBUFFERED=1 \
    AGENT_PORT=8089

EXPOSE 8089

CMD ["python", "agent.py"]
