#!/bin/bash
echo "🚀 Iniciando CashLens..."
echo "📦 MongoDB: mongodb://localhost:27017/cash_lens"
echo "🔴 Redis: redis://localhost:6379"
echo "🌐 Aplicação: http://localhost:4000"
echo ""
mix phx.server
