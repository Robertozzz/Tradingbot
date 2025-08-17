
from sqlalchemy.orm import declarative_base, Mapped, mapped_column, relationship
from sqlalchemy import String, Integer, Float, ForeignKey, DateTime
from datetime import datetime

Base = declarative_base()

class Plan(Base):
    __tablename__ = "plans"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    symbol: Mapped[str] = mapped_column(String, index=True)
    side: Mapped[str] = mapped_column(String)  # BUY/SELL (BUY only implemented)
    quote_amount: Mapped[float] = mapped_column(Float)  # in BASE asset (e.g., USDT)
    status: Mapped[str] = mapped_column(String, default="CREATED")
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)

    entries = relationship("Entry", back_populates="plan", cascade="all, delete-orphan")
    take_profits = relationship("TakeProfit", back_populates="plan", cascade="all, delete-orphan")
    stop_loss = relationship("StopLoss", back_populates="plan", uselist=False, cascade="all, delete-orphan")

class Entry(Base):
    __tablename__ = "entries"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id"))
    price: Mapped[float] = mapped_column(Float)
    fraction: Mapped[float] = mapped_column(Float)
    order_id: Mapped[str | None] = mapped_column(String, nullable=True)
    filled_qty: Mapped[float] = mapped_column(Float, default=0.0)
    status: Mapped[str] = mapped_column(String, default="PENDING")

    plan = relationship("Plan", back_populates="entries")

class TakeProfit(Base):
    __tablename__ = "take_profits"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id"))
    price: Mapped[float] = mapped_column(Float)
    fraction: Mapped[float] = mapped_column(Float)
    order_id: Mapped[str | None] = mapped_column(String, nullable=True)
    filled_qty: Mapped[float] = mapped_column(Float, default=0.0)
    status: Mapped[str] = mapped_column(String, default="PENDING")

    plan = relationship("Plan", back_populates="take_profits")

class StopLoss(Base):
    __tablename__ = "stop_losses"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id"))
    stop_price: Mapped[float] = mapped_column(Float)
    limit_price: Mapped[float] = mapped_column(Float)
    order_id: Mapped[str | None] = mapped_column(String, nullable=True)
    remaining_qty: Mapped[float] = mapped_column(Float, default=0.0)
    status: Mapped[str] = mapped_column(String, default="PENDING")

    plan = relationship("Plan", back_populates="stop_loss")
