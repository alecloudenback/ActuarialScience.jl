include("decrement.jl")

abstract type InterestCompounding end

struct Simple <: InterestCompounding end
struct Compound <: InterestCompounding end
struct Continuous <: InterestCompounding end

"""
    InterestRate() 

`InterestRate` is an abstract type that is the parent of various 
concrete implementations of interest rate calculations.
"""
abstract type InterestRate <: Decrement end

"""
    FunctionalInterestRate()

`FunctionalInterestRate` is a struct with a `rate_function` that is a function that
takes a time and returns an annual interst rate for that time. Construct by calling
    `InterestRate()` with a function as an argument. 

# Examples
    # simply return 5% always
    InterestRate(time -> 0.05) 
    
    # for every period, return a normally distrubted rate
    InterestRate((x -> rand(Normal(0.05, 0.01))))

    # an autocorrelated rate
    InterestRate(
            time -> time <= 1 ? 0.05 : rand(Normal(last(i5.rate), 0.01)),
        )
"""
struct FunctionalInterestRate{F} <: InterestRate
    rate::Array{Float64,1} # keep track of prior rates for autocorrelation
    rate_function::F
    compound::InterestCompounding
end

"""
    VectorInterestRate()

`VectorInterestRate` is a struct with a given vector where the element `t` is the rate at time `t`.
Construct by calling `InterestRate()` with a vector as an argument. Note that if you provide a short
vector, you may inhibit other methods (e.g. commutation/insurance calculations) becuase you haven't 
defined interest rates for longer-dated periods.

# Examples
    # 5% interest for years 1, 2, and 3
    InterestRate([0.05, 0.05, 0.05])
"""
struct VectorInterestRate{T} <: InterestRate
    rate
    compound::InterestCompounding
end


"""
    ConstantInterestRate()

`ConstantInterestRate` is a struct with a given rate that will act as the same rate for all periods.
Construct by calling `InterestRate()` with a rate as an argument. 

# Examples
    # 5% interest for all years
    InterestRate()
"""
struct ConstantInterestRate <: InterestRate
    rate
    compound::InterestCompounding
end


"""
    InterestRate(v::Vector{Float64})

Construct a `VectorInterestRate`.
"""
function InterestRate(v::Vector{Float64},times::Vector{T} = nothing; compound=Compound()) where {T}
    if isnothing(times) 
        times =  [t for t in 1:length(v)]
    end
    int = LinearInterpolation(times,v,extrapolation_bc = Flat())
    VectorInterestRate(int,compound)
end

"""
    InterestRate(i::Real)

Construct a `ConstantInterestRate`.
"""
function InterestRate(i::Real; compound=Compound())
    ConstantInterestRate(i,compound)
end

"""
    InterestRate(f)

Construct a `FunctionalInterestRate`. Assumes that `f` is a function that takes a given time
period and returns the annual effective rate for that period.
"""
function InterestRate(f; compound=Continuous())
    FunctionalInterestRate(Vector{Float64}(undef, 0), f,compound)
end

# make interest rates broadcastable
Base.broadcastable(i::InterestRate) = Ref(i)


"""
        rate(i::InterestRate,time)

The interst during time `time.`
"""
function rate(i::ConstantInterestRate, time)
    return i.rate
end

function rate(i::FunctionalInterestRate{F}, time) where {F}
    if time <= lastindex(i.rate)
        return i.rate[time]
    else
        rate = i.rate_function(time)
        push!(i.rate, rate)
        return rate
    end
end

function rate(i::VectorInterestRate, time)
    return i.rate(time)
end

"""
    v(i::InterestRate, from_period, to_period)
    v(i::InterestRate, period)

The three argument method returns the discount factor applicable between period `from_period` and `to_period` given `InterestRate` `i`.
The two argument method returns the discount factor from period zero to `period` given `InterestRate` `i`.

# Examples
```julia-repl
julia> i = InterestRate(0.05)
julia> v(i,1)
0.9523809523809523
julia> v.(i,1:5)
5-element Array{Float64,1}:
 0.9523809523809523
 0.9070294784580498
 0.863837598531476
 0.8227024747918819
 0.7835261664684589
 julia> v(i,1,3)
0.9070294784580498
```

"""
function v(i::InterestRate, from_period::Int, to_period::Int)
    return v(i,to_period) ./ v(i,from_period)
end

"""
    v(i::InterestRate, to_time)    
The discount rate at time `to_time`.
"""
function v(i::InterestRate, to_time::Int) 
    reduce(/, 1 .+ rate.(i,1:to_time);init=1.0 )
end

function v(i::InterestRate, from_time, to_time) 
    @show quadgk(t -> rate(i,t), from_time,to_time)
    1.0 / (1 + quadgk(t -> rate(i,t), from_time,to_time)[1])
end

function v(i::InterestRate, to_time) 
    1.0 * v(i,0,to_time)
end

""" 
    omega(i::InterestRate)

The last period that the interest rate is defined for. Assumed to be infinite (`Inf`) for 
    functional and constant interest rate types. Returns the `lastindex` of the vector if 
    a vector type. Also callable using `ω` instead of `omega`.

"""
function mt.omega(i::ConstantInterestRate)
    return Inf
end

function mt.omega(i::VectorInterestRate)
    return lastindex(i.i)
end

function mt.omega(i::FunctionalInterestRate{F}) where {F}
    return Inf
end


# Iterators

"""
`timestep` is the fractional portion of the rate period. E.g. if you are using annual rates, then `time_step` is fraction of the year in each of the itereated time steps.
"""
struct DiscountFactor{T<:InterestRate}
    int::T
    time_step 
end

(i::InterestRate)(time_period) = DiscountFactor(i,time_period)

function Base.iterate(df::DiscountFactor{T}) where {T<:InterestRate}
    return (1.0,(v = 1.0 * v(df.int,df.time_step),time = df.time_step))
end

function Base.iterate(df::DiscountFactor{ConstantInterestRate},state) 
    new_time =  df.time_step + df.time_step
    return (state.v,(v = state.v  * v(df.int,df.time_step,new_time),time = new_time))
end

function Base.IteratorSize(::Type{<:DiscountFactor{T}}) where {T<:InterestRate}
    # if SizeUnkown, then can end up growing infinitely with `collect` for FunctionalInterestRate
    return Base.IsInfinite()
end

function Base.length(df::DiscountFactor{VectorInterestRate{T}})  where {T<:Number}
    return length(df.int.rate) + 1
end

function Base.IteratorSize(::Type{<:DiscountFactor{VectorInterestRate{T}}}) where {T<:Number}
    return Base.HasLength()
end