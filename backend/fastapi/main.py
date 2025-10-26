from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from datetime import datetime
import os

app = FastAPI(
    title="FastAPI Service",
    description="FastAPI backend for DevOps Pipeline",
    version="1.0.0"
)

# CORS 설정
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/")
async def root():
    return {
        "service": "FastAPI",
        "status": "running",
        "timestamp": datetime.now().isoformat(),
        "message": "Welcome to FastAPI Service"
    }

@app.get("/health")
async def health():
    return {
        "status": "healthy",
        "timestamp": datetime.now().isoformat()
    }

@app.get("/api/hello")
async def hello():
    return {
        "message": "Hello from FastAPI!",
        "timestamp": datetime.now().isoformat()
    }

@app.get("/api/info")
async def info():
    return {
        "service": "FastAPI",
        "version": "1.0.0",
        "environment": os.getenv("FASTAPI_ENV", "development"),
        "timestamp": datetime.now().isoformat()
    }

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
