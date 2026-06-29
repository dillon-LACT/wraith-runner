from dotenv import load_dotenv
import os

load_dotenv()

DATABASE_PATH: str = os.getenv("DATABASE_PATH", "jobs.db")
ADMIN_KEY: str = os.environ["ADMIN_KEY"]
HOST: str = os.getenv("HOST", "0.0.0.0")
PORT: int = int(os.getenv("PORT", "8002"))
