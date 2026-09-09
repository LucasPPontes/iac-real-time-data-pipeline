import json
import os
import urllib.request
import urllib.error
import boto3
import logging

# Configuração de logging
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Variáveis de ambiente
API_URL = os.environ.get("API_URL", "http://fastapi-app:8001/telemetria")
KINESIS_STREAM_NAME = os.environ.get("KINESIS_STREAM_NAME", "telemetry-stream")
FIREHOSE_STREAM_NAME = os.environ.get("FIREHOSE_STREAM_NAME", "telemetry-firehose")
AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")

# Inicialização dos clientes boto3 com compatibilidade para LocalStack
endpoint_url = os.environ.get("AWS_ENDPOINT_URL") or os.environ.get("LOCALSTACK_HOSTNAME")
if endpoint_url:
    if not endpoint_url.startswith("http"):
        endpoint_url = f"http://{endpoint_url}:4566"
    kinesis_client = boto3.client("kinesis", region_name=AWS_REGION, endpoint_url=endpoint_url)
    firehose_client = boto3.client("firehose", region_name=AWS_REGION, endpoint_url=endpoint_url)
else:
    kinesis_client = boto3.client("kinesis", region_name=AWS_REGION)
    firehose_client = boto3.client("firehose", region_name=AWS_REGION)


def lambda_handler(event, context):
    """
    Função Lambda Coletora:
    1. Faz requisição HTTP GET na API FastAPI (usando a rede interna do Docker).
    2. Lê os dados de telemetria dos sensores IoT.
    3. Publica o payload JSON no Amazon Kinesis Data Stream e no Amazon Data Firehose.
    """
    logger.info(f"Buscando telemetria na API: {API_URL}")
    
    try:
        req = urllib.request.Request(
            API_URL,
            headers={"User-Agent": "AWS-Lambda-Collector/1.0", "Accept": "application/json"}
        )
        with urllib.request.urlopen(req, timeout=10) as response:
            if response.status != 200:
                logger.error(f"Erro HTTP na requisição: status {response.status}")
                return {"statusCode": response.status, "body": "Falha ao obter telemetria"}
            
            content = response.read().decode('utf-8')
            telemetry_data = json.loads(content)
            logger.info(f"Dados obtidos com sucesso: {telemetry_data}")
            
    except Exception as e:
        logger.error(f"Erro ao buscar telemetria da API ({API_URL}): {str(e)}")
        raise e

    partition_key = str(telemetry_data.get("device_id", "default_sensor"))
    record_bytes = (json.dumps(telemetry_data) + "\n").encode("utf-8")

    # 1. Enviar registro ao Kinesis Data Stream
    try:
        kinesis_res = kinesis_client.put_record(
            StreamName=KINESIS_STREAM_NAME,
            Data=record_bytes,
            PartitionKey=partition_key
        )
        logger.info(f"Enviado ao Kinesis Stream. SequenceNumber: {kinesis_res.get('SequenceNumber')}")
    except Exception as kinesis_err:
        logger.error(f"Erro ao publicar no Kinesis Stream: {str(kinesis_err)}")
        raise kinesis_err

    # 2. Enviar registro ao Amazon Data Firehose (DirectPut para o S3 Data Lake)
    try:
        firehose_res = firehose_client.put_record(
            DeliveryStreamName=FIREHOSE_STREAM_NAME,
            Record={"Data": record_bytes}
        )
        logger.info(f"Enviado ao Data Firehose. RecordId: {firehose_res.get('RecordId')}")
    except Exception as firehose_err:
        logger.error(f"Erro ao publicar no Data Firehose: {str(firehose_err)}")
        raise firehose_err

    return {
        "statusCode": 200,
        "body": json.dumps({
            "status": "success",
            "message": "Telemetria enviada com sucesso ao Kinesis e ao Firehose S3 Data Lake",
            "device_id": partition_key,
            "kinesis_sequence": kinesis_res.get("SequenceNumber"),
            "firehose_record_id": firehose_res.get("RecordId")
        })
    }

