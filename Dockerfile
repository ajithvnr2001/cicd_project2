# Python base image edu
FROM python:3.9-slim

# Work folder set pannu
WORKDIR /app

# Code-a copy pannu
COPY . .

# Flask install pannu
RUN pip install flask

# App-a run pannu
CMD ["python", "main.py"]