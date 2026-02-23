from fastapi import FastAPI, HTTPException
import FinanceDataReader as fdr
import pandas as pd

# FastAPI 객체 생성
app = FastAPI()

# 1. 메인 화면 (루트 경로)
@app.get("/")
def read_root():
    return {"message": "나의 주식 API 서버가 정상 작동 중입니다!", "status": "online"}

# 2. 특정 종목 주가 조회 API
@app.get("/stock/{code}")
def get_stock_price(code: str, days: int = 10):
    """
    code: 주식 종목 코드 (예: 005930)
    days: 최근 며칠 치 데이터를 가져올지 결정 (기본값: 10일)
    """
    try:
        # FinanceDataReader로 데이터 가져오기
        df = fdr.DataReader(code)
        
        # 데이터가 없는 경우 (잘못된 코드를 입력했을 때)
        if df.empty:
            raise HTTPException(status_code=404, detail="종목 코드를 찾을 수 없거나 데이터가 없습니다.")
        
        # 최근 'days' 일치 데이터만 추출
        df = df.tail(days)
        
        # JSON으로 예쁘게 변환하기 위한 전처리 (날짜를 문자로 변환)
        df = df.reset_index()
        df['Date'] = df['Date'].dt.strftime('%Y-%m-%d')
        
        # 데이터를 딕셔너리 형태로 변환하여 반환
        return {
            "code": code,
            "data": df.to_dict(orient="records")
        }
        
    except Exception as e:
        # 서버 내부 오류 발생 시 안전하게 에러 메시지 반환
        raise HTTPException(status_code=500, detail=str(e))