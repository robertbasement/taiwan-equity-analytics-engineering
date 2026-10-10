FROM python:3.11-slim

WORKDIR /app

ARG DBT_CODE_GIT_SHA
RUN DBT_CODE_GIT_SHA="$DBT_CODE_GIT_SHA" python -c \
    "import os, re; assert re.fullmatch(r'[0-9a-f]{40}', os.environ['DBT_CODE_GIT_SHA']), 'DBT_CODE_GIT_SHA must be a full lowercase Git SHA'"
ENV DBT_CODE_GIT_SHA=$DBT_CODE_GIT_SHA

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

ENV DBT_PROFILES_DIR=/app

RUN chmod +x run_dbt.sh

ENTRYPOINT ["./run_dbt.sh"]
