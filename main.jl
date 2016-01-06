"""
A Promise is a placeholder for a value which isn't yet known.
Though we may know what type it will be hence Promises take
the type of their eventual value as a parameter
"""
abstract Promise{T}

"""
When you want to get the actual value of a Promise you just call `need`
on it. It's safe to call `need` on all types so if in doubt...need it
"""
function need(x::Any) x end

"Deferred's enable lazy evaluation"
type Deferred{T} <: Promise{T}
  thunk::Function
  state::Symbol
  value::T
  error::Exception
  Deferred(f::Function) = new(f, :pending)
end

"Make the type parameter optional"
Deferred(f::Function) = Deferred{Any}(f)

"""
The first time a Deferred is needed it's thunk is called and the
result is stored. Whether it return or throws. From then on it
will just replicate this result without re-running the thunk
"""
function need(d::Deferred)
  d.state == :evaled && return d.value
  d.state == :failed && rethrow(d.error)
  try
    d.value = d.thunk()
    d.state = :evaled
    d.value
  catch e
    d.state = :failed
    d.error = e
    rethrow(e)
  end
end

test("need") do
  array = Deferred(vcat)
  @test need(1) == 1
  @test need(array) == vcat()
  @test need(array) === need(array)
  @test isa(@catch(need(Deferred(error))), ErrorException)
  test("with types") do
    @test need(Deferred{Vector}(vcat)) == vcat()
    @test isa(@catch(need(Deferred{Vector}(string))), MethodError)
  end
end

"""
Create a Deferred from an Expr. If `body` is annotated with a
type `x` then create a `Deferred{x}`
"""
macro defer(body)
  if isa(body, Expr) && body.head == symbol("::")
    :(Deferred{$(esc(body.args[2]))}(()-> $(esc(body.args[1]))))
  else
    :(Deferred{Any}(()-> $(esc(body))))
  end
end

test("@defer") do
  @test need(@defer 1) == 1
  @test isa(@catch(need(@defer error())), ErrorException)
  @test typeof(@defer 1) == Deferred{Any}
  @test typeof(@defer 1::Int) == Deferred{Int}
end

"""
Results are intended to provide a way for asynchronous processes
to communicate their result to other threads
"""
type Result{T} <: Promise{T}
  cond::Condition
  state::Symbol
  value::T
  error::Exception
  Result() = new(Condition(), :pending)
  Result(c::Condition) = new(c, :pending)
end

"Make the type optional"
Result() = Result{Any}()

"Await the result if its pending. Otherwise reproduce it cached value or exception"
function need(r::Result)
  r.state == :evaled && return r.value
  r.state == :failed && rethrow(r.error)
  r.state == :needed && return wait(r.cond)
  try
    r.state = :needed
    r.value = wait(r.cond)
    r.state = :evaled
    r.value
  catch e
    r.state = :failed
    r.error = e
    rethrow(e)
  end
end

"Give the Promise its value"
function Base.write(r::Result, value)
  if r.state == :pending
    r.state = :evaled
    r.value = value
  end
  notify(r.cond, value)
end

test("write") do
  result = Result()
  task = @async need(result)
  write(result, 1)
  @test need(result) == 1
  @test wait(task) == 1
end

"Put the Promise into a failed state"
function Base.error(r::Result, e::Exception)
  if r.state == :pending
    r.state = :failed
    r.error = e
  end
  notify(r.cond, e; error=true)
end

test("error") do
  result = Result()
  task = @async need(result)
  error(result, ErrorException(""))
  @test isa(@catch(need(result)), ErrorException)
  @test @catch(need(result)) === @catch wait(task)
  @test task.result == result.error
  @test task.state == :failed
end

"""
Run body in a seperate thread and communicate the result with a Result
which is the only difference between this and @Base.async which returns
a Task
"""
macro thread(body)
  if isa(body, Expr) && body.head == symbol("::")
    body,T = body.args
  else
    T = Any
  end
  quote
    result = Result{$T}()
    schedule(@task try
      write(result, $(esc(body)))
    catch e
      error(result, e)
    end)
    result
  end
end

test("@thread") do
  @test need(@thread 1) == 1
  @test isa(@catch(need(@thread error())), ErrorException)
  @test typeof(@thread 1) == Result{Any}
  @test typeof(@thread 1::Int) == Result{Int}
end
