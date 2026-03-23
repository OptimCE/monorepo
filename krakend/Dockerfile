FROM python:3.14-slim@sha256:fb83750094b46fd6b8adaa80f66e2302ecbe45d513f6cece637a841e1025b4ca
WORKDIR /app
RUN python -m pip install --no-cache-dir pyyaml
COPY swagger2krakend/app.py /app/app.py
ENTRYPOINT ["python", "/app/app.py"]
CMD ["swagger.yaml", "-o", "krakend.json"]
