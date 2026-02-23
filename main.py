from fastapi import FastAPI, HTTPException
import FinanceDataReader as fdr
import pandas as pd

app = FastAPI()

# 1. 메인 화면 (루트 경로)
@app.get("/")
def read_root():
    return {"message": "나의 주식 API 서버가 정상 작동 중입니다!", "status": "online"}

# 2. 한국 주식 전체 리스트 가져오기 (이건 잘 작동하고 있었습니다!)
@app.get("/stocks/krx")
def get_krx_list():
    try:
        df_krx = fdr.StockListing('KRX')
        df_krx = df_krx.fillna("") # 빈칸 처리
        krx_list = df_krx.to_dict(orient="records")
        return {
            "market": "KRX",
            "total_count": len(krx_list),
            "data": krx_list
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

# 3. 🌟 [수정/추가] 특정 종목 주가 및 이동평균선 데이터 가져오기
@app.get("/stock/{code}")
def get_stock_price(code: str, days: int = 300):
    try:
        # 전체 데이터를 불러옵니다. (이동평균선을 계산하려면 과거 데이터가 넉넉히 필요함)
        df = fdr.DataReader(code)
        
        if df.empty:
            raise HTTPException(status_code=404, detail="종목 코드를 찾을 수 없거나 데이터가 없습니다.")
        
        # 🌟 이동평균선(MA) 계산하기
        df['MA5'] = df['Close'].rolling(window=5).mean()
        df['MA20'] = df['Close'].rolling(window=20).mean()
        df['MA60'] = df['Close'].rolling(window=60).mean()
        df['MA120'] = df['Close'].rolling(window=120).mean()
        df['MA240'] = df['Close'].rolling(window=240).mean()
        
        # NaN(계산이 안 된 빈칸)을 빈 문자열로 처리 (앱에서 파싱 에러 방지)
        df = df.fillna("")
        
        # 앱에서 요청한 일수(days)만큼만 최근 데이터 잘라내기
        df = df.tail(days)
        
        # 인덱스(날짜)를 일반 열(Column)로 빼내고 문자로 변환
        df = df.reset_index()
        df['Date'] = df['Date'].dt.strftime('%Y-%m-%d')
        
        # 최종적으로 앱에 전송!
        return {
            "code": code,
            "data": df.to_dict(orient="records")
        }
        
    except Exception as e:
        # 에러 발생 시 500 에러 전송
        raise HTTPException(status_code=500, detail=str(e))