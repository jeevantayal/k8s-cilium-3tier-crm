from flask import Flask
import os
import psycopg2

app = Flask(__name__)

@app.route("/health")
def health():
    return "OK", 200

@app.route("/")
def index():
    return "CRM App is running", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)

