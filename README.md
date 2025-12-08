# CashLens

Aplicação Phoenix LiveView com suporte para MongoDB, Redis e serviço ML em Python.

## Requisitos

- Elixir 1.18.4+ 
- Erlang/OTP 28+
- MongoDB (localhost:27017)
- Redis (localhost:6379)
- Python 3.12+ (para ML)

**OU**

- Docker & Docker Compose

## Instalação

### Local
```bash
mix deps.get
mix compile

# Para o serviço ML
cd ml
pip install -r requirements.txt
```

### Docker
```bash
docker-compose up --build
```

## Executar

### Local
```bash
./start.sh
# ou
mix phx.server

# Serviço ML (separado)
cd ml && uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

### Docker
```bash
./docker-start.sh
# ou
docker-compose up
```

Acesse: 
- Aplicação: http://localhost:4000
- ML Service: http://localhost:8000/docs

## Funcionalidades

- ✅ Phoenix LiveView
- ✅ MongoDB (mongodb_driver)
- ✅ Redis (redix)
- ✅ Interface para testar conexões
- ✅ Dashboard básico
- ✅ Docker Compose
- ✅ Serviço ML (FastAPI + CatBoost)
