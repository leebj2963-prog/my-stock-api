from fastapi import FastAPI
import FinanceDataReader as fdr
import datetime
import pandas as pd

app = FastAPI()

@app.get("/api/stock_list")
def get_stock_list():
    df = fdr.StockListing('KRX')[['Code', 'Name']]
    return df.to_dict(orient="records")

@app.get("/api/stock_data/{code}")
def get_stock_data(code: str):
    start_date = datetime.datetime.now() - datetime.timedelta(days=1095)
    
    try:
        df = fdr.DataReader(code, start_date)
    except Exception:
        return [] # 에러가 나면 빈 데이터 반환

    # 🌟 [핵심 안전장치] 데이터가 아예 없거나, 종가/거래량 컬럼이 없으면 빈 리스트를 반환하여 튕김 방지!
    if df.empty or 'Close' not in df.columns or 'Volume' not in df.columns:
        return []

    df = df.dropna(subset=['Close', 'Volume'])
    
    # 이동평균선 계산 (기존 v2.1 기능 이식)
    for window in [5, 20, 60, 120, 240]:
        df[f'MA{window}'] = df['Close'].rolling(window).mean()
        
    df.reset_index(inplace=True)
    df['Date'] = df['Date'].dt.strftime('%Y-%m-%d')
    return df.fillna("").to_dict(orient="records")