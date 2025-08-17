
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.orm import selectinload
from sqlalchemy import select
from .models import Base, Plan, Entry, TakeProfit, StopLoss
from .config import DATABASE_URL

engine = create_async_engine(DATABASE_URL, echo=False, future=True)
SessionLocal = async_sessionmaker(engine, expire_on_commit=False)

async def init_db():
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)

async def create_plan(session: AsyncSession, plan: Plan):
    session.add(plan)
    await session.commit()
    await session.refresh(plan)
    return plan

async def get_plan(session: AsyncSession, plan_id: int):
    result = await session.execute(
        select(Plan).where(Plan.id == plan_id).options(
            selectinload(Plan.entries),
            selectinload(Plan.take_profits),
            selectinload(Plan.stop_loss),
        )
    )
    return result.scalar_one_or_none()

async def list_plans(session: AsyncSession):
    result = await session.execute(select(Plan))
    return result.scalars().all()
