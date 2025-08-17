
from pydantic import BaseModel, Field, field_validator
from typing import List, Optional, Literal

class EntrySpec(BaseModel):
    price: float = Field(..., gt=0)
    fraction: float = Field(..., gt=0, le=1)

class TPSpec(BaseModel):
    price: float = Field(..., gt=0)
    fraction: float = Field(..., gt=0, le=1)

class SLSpec(BaseModel):
    stop_price: float = Field(..., gt=0)
    limit_price: float = Field(..., gt=0)

class CreatePlanRequest(BaseModel):
    symbol: str
    side: Literal["BUY", "SELL"]
    quote_amount: float = Field(..., gt=0)
    entries: List[EntrySpec]
    take_profits: List[TPSpec]
    stop_loss: Optional[SLSpec]

    @field_validator("entries")
    @classmethod
    def entries_sum_leq_1(cls, v):
        s = sum(e.fraction for e in v)
        if s > 1.0 + 1e-9:
            raise ValueError("Sum of entry fractions must be <= 1.0")
        return v

    @field_validator("take_profits")
    @classmethod
    def tp_sum_leq_1(cls, v):
        s = sum(t.fraction for t in v)
        if s > 1.0 + 1e-9:
            raise ValueError("Sum of TP fractions must be <= 1.0")
        return v

class PlanResponse(BaseModel):
    id: int
    symbol: str
    side: str
    quote_amount: float
    status: str
    entries: list
    take_profits: list
    stop_loss: dict | None
