from fastapi import FastAPI, HTTPException
import FinanceDataReader as fdr
import pandas as pd
from functools import lru_cache
from datetime import datetime, timedelta  # 🌟 [추가] 날짜 계산을 위한 모듈

app = FastAPI()

@app.get("/")
def read_root():
    return {"message": "나의 주식 API 서버가 정상 작동 중입니다!", "status": "online"}

# 🌟 [개선] FastAPI 라우터에 직접 캐시를 걸기보다, 데이터를 가져오는 함수를 따로 빼서 캐시하는 것이 훨씬 안정적입니다.
@lru_cache(maxsize=1) 
def fetch_krx_list():
    df_krx = fdr.StockListing('KRX')
    df_krx = df_krx.fillna("")
    return df_krx.to_dict(orient="records")

@app.get("/stocks/krx")
def get_krx_list():
    try:
        krx_list = fetch_krx_list()
        return {
            "market": "KRX",
            "total_count": len(krx_list),
            "data": krx_list
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@lru_cache(maxsize=20) # 최근 검색한 20개 종목 메모리 기억!
def fetch_and_calculate_stock_data(code: str, days: int):
    # 🌟 [핵심 속도 개선] 30년 치 데이터를 다 가져오지 않고, 필요한 기간만 계산해서 가져옵니다!
    # 요청일수(days) + 240일선 계산용(240) + 주말/휴일 여유분(150) = 필요한 만큼의 과거 날짜 계산
    start_date = (datetime.now() - timedelta(days=days + 390)).strftime('%Y-%m-%d')
    
    # 지정한 날짜부터 오늘까지만 딱! 가져옵니다. (데이터량이 1/10로 줄어듦)
    df = fdr.DataReader(code, start_date)
    
    if df.empty:
        return None
    
    # 이동평균선(MA) 계산
    df['MA5'] = df['Close'].rolling(window=5).mean()
    df['MA20'] = df['Close'].rolling(window=20).mean()
    df['MA60'] = df['Close'].rolling(window=60).mean()
    df['MA120'] = df['Close'].rolling(window=120).mean()
    df['MA240'] = df['Close'].rolling(window=240).mean()
    
    df = df.fillna("")
    df = df.tail(days) # 계산이 끝난 후 최종적으로 요청한 날짜만큼만 잘라냅니다.
    
    df = df.reset_index()
    df['Date'] = df['Date'].dt.strftime('%Y-%m-%d')
    
    return df.to_dict(orient="records")

@app.get("/stock/{code}")
def get_stock_price(code: str, days: int = 300):
    try:
        data = fetch_and_calculate_stock_data(code, days)
        
        if data is None:
            raise HTTPException(status_code=404, detail="종목 코드를 찾을 수 없거나 데이터가 없습니다.")
        
        return {
            "code": code,
            "data": data
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))