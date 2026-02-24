from fastapi import FastAPI, HTTPException
import FinanceDataReader as fdr
import pandas as pd
from functools import lru_cache  # 🌟 [추가] 캐시(기억) 기능을 위한 모듈

app = FastAPI()

@app.get("/")
def read_root():
    return {"message": "나의 주식 API 서버가 정상 작동 중입니다!", "status": "online"}

# 🌟 [수정] 종목 리스트도 하루에 한 번만 긁어오면 되므로 캐시 적용 (속도 대폭 향상)
@app.get("/stocks/krx")
@lru_cache(maxsize=1) 
def get_krx_list():
    try:
        df_krx = fdr.StockListing('KRX')
        df_krx = df_krx.fillna("")
        krx_list = df_krx.to_dict(orient="records")
        return {
            "market": "KRX",
            "total_count": len(krx_list),
            "data": krx_list
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 🌟 [추가] 시간이 오래 걸리는 '데이터 다운로드 + MA 계산' 작업을 따로 빼서 캐시(저장)합니다.
@lru_cache(maxsize=30) # 최근 검색한 100개 종목의 결과를 메모리에 기억!
def fetch_and_calculate_stock_data(code: str, days: int):
    df = fdr.DataReader(code)
    
    if df.empty:
        return None
    
    # 이동평균선(MA) 계산
    df['MA5'] = df['Close'].rolling(window=5).mean()
    df['MA20'] = df['Close'].rolling(window=20).mean()
    df['MA60'] = df['Close'].rolling(window=60).mean()
    df['MA120'] = df['Close'].rolling(window=120).mean()
    df['MA240'] = df['Close'].rolling(window=240).mean()
    
    df = df.fillna("")
    df = df.tail(days)
    
    df = df.reset_index()
    df['Date'] = df['Date'].dt.strftime('%Y-%m-%d')
    
    return df.to_dict(orient="records")

# 🌟 [수정] 메인 요청 API는 이제 직접 계산하지 않고, 캐시된 함수를 호출만 합니다.
@app.get("/stock/{code}")
def get_stock_price(code: str, days: int = 300):
    try:
        # 거래소에 새로 요청하지 않고, 기억된 데이터가 있으면 0.1초 만에 바로 가져옵니다.
        data = fetch_and_calculate_stock_data(code, days)
        
        if data is None:
            raise HTTPException(status_code=404, detail="종목 코드를 찾을 수 없거나 데이터가 없습니다.")
        
        return {
            "code": code,
            "data": data
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))