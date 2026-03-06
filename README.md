# Webapp

A simple containerized webapp with a fancy glassmorphism UI, served by nginx.

## Run locally

```bash
docker build -t webapp .
docker run -p 8080:80 webapp
```

Then open http://localhost:8080
