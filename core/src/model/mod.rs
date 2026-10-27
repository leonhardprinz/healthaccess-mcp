//! Serde models for everything in the Health Access folder.

pub mod day;
pub mod index;
pub mod plan;
pub mod vitals;
pub mod workout;
pub mod workout_v0;

pub use day::Day;
pub use index::{Index, IndexEntry};
pub use plan::{Goal, Plan, PlanBlock, PlanStatus, PlanStep};
pub use vitals::Vitals;
pub use workout::{
    EffortSource, HrSample, Lap, PlanRef, RecoveryHr, Step, StepKind, Workout, ZoneSeconds, Zones,
};
pub use workout_v0::WorkoutV0;
