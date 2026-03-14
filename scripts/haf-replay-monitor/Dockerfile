FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates/ templates/
EXPOSE 8082
CMD ["gunicorn", "-b", "0.0.0.0:8082", "-w", "2", "app:app"]
