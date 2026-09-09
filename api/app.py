import random
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional
from fastapi import FastAPI

app = FastAPI(
    title="IoT Telemetry Generator API",
    description="API simuladora de telemetria de sensores IoT com geração de anomalias",
    version="1.0.0"
)

DEVICES: List[Dict[str, Any]] = [
    {"id": "sensor_temperatura_01", "type": "temperatura", "unit": "°C", "base_range": (18.0, 32.0), "zone": "ZONE_A"},
    {"id": "sensor_temperatura_02", "type": "temperatura", "unit": "°C", "base_range": (25.0, 45.0), "zone": "ZONE_B"},
    {"id": "sensor_pressao_01", "type": "pressao", "unit": "bar", "base_range": (1.0, 4.5), "zone": "ZONE_A"},
    {"id": "sensor_pressao_02", "type": "pressao", "unit": "bar", "base_range": (2.0, 8.0), "zone": "ZONE_C"},
    {"id": "sensor_vibracao_01", "type": "vibracao", "unit": "Hz", "base_range": (10.0, 120.0), "zone": "ZONE_B"},
    {"id": "sensor_umidade_01", "type": "umidade", "unit": "%", "base_range": (40.0, 90.0), "zone": "ZONE_C"},
]


@app.get("/")
def read_root():
    return {"message": "IoT Telemetry Simulation API is running", "docs": "/docs"}


@app.get("/health")
def health_check():
    return {"status": "healthy", "timestamp": datetime.now(timezone.utc).isoformat()}


@app.get("/telemetria")
def get_telemetry() -> Dict[str, Any]:
    """
    Retorna uma leitura simulada de um dispositivo de telemetria IoT.
    Aproximadamente 15% das chamadas geram anomalias propositais para testes do pipeline.
    """
    device = random.choice(DEVICES)
    
    # 15% de probabilidade de gerar anomalia
    is_anomaly = random.random() < 0.15
    anomaly_type: Optional[str] = None
    
    if is_anomaly:
        anomaly_choice = random.choice(["spike", "null", "out_of_bounds", "critical_status"])
        if anomaly_choice == "spike":
            reading_value = round(random.uniform(500.0, 1500.0), 2)
            status = "CRITICAL"
            anomaly_type = "extreme_temperature_spike"
        elif anomaly_choice == "null":
            reading_value = None
            status = "ERROR"
            anomaly_type = "sensor_missing_value"
        elif anomaly_choice == "out_of_bounds":
            reading_value = round(random.uniform(-999.0, -100.0), 2)
            status = "ERROR"
            anomaly_type = "negative_reading"
        else:
            reading_value = round(random.uniform(*device["base_range"]), 2)
            status = "CRITICAL_OVERHEAT"
            anomaly_type = "status_alert"
    else:
        reading_value = round(random.uniform(*device["base_range"]), 2)
        status = random.choice(["NORMAL", "NORMAL", "NORMAL", "NORMAL", "WARNING"])

    payload = {
        "device_id": device["id"],
        "sensor_type": device["type"],
        "reading_value": reading_value,
        "unit": device["unit"],
        "location_zone": device["zone"],
        "operational_status": status,
        "is_anomaly": is_anomaly,
        "anomaly_type": anomaly_type,
        "timestamp": datetime.now(timezone.utc).isoformat()
    }
    
    return payload
