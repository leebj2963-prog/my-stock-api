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
# 기존 코드 아래에 이어서 작성하세요.

@app.get("/stocks/krx")
def get_krx_list():
    """
    한국 거래소(KRX) 전체 상장 종목 리스트를 가져옵니다.
    """
    try:
        # 1. KRX 전체 종목 데이터 가져오기
        df_krx = fdr.StockListing('KRX')
        
        # 2. JSON 변환 오류 방지: 빈칸(NaN)을 빈 문자열("")로 채우기
        df_krx = df_krx.fillna("")
        
        # 3. 데이터를 딕셔너리 리스트 형태로 변환
        krx_list = df_krx.to_dict(orient="records")
        
        # 4. 결과 반환 (총 종목 수도 함께 알려주면 좋습니다)
        return {
            "market": "KRX",
            "total_count": len(krx_list),
            "data": krx_list
        }
        
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))