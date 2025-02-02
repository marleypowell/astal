local lgi = require("lgi")
local Astal = lgi.require("Astal", "0.1")
local GObject = lgi.require("GObject", "2.0")
local Binding = require("astal.binding")
local Time = require("astal.time")
local Process = require("astal.process")

---@class Variable
---@field private variable table
---@field private err_handler? function
---@field private _value any
---@field private _poll? table
---@field private _watch? table
---@field private poll_interval number
---@field private poll_exec? string[] | string
---@field private poll_transform? fun(next: any, prev: any): any
---@field private poll_fn? function
---@field private watch_transform? fun(next: any, prev: any): any
---@field private watch_exec? string[] | string
local Variable = {}
Variable.__index = Variable

---@param value any
---@return Variable
function Variable.new(value)
    local v = Astal.VariableBase()
    local variable = setmetatable({
        variable = v,
        _value = value,
    }, Variable)
    v.on_dropped = function()
        variable:stop_watch()
        variable:stop_watch()
    end
    v.on_error = function(_, err)
        if variable.err_handler then
            variable.err_handler(err)
        end
    end
    return variable
end

---@param transform function
---@return Binding
function Variable:__call(transform)
    if transform == nil then
        transform = function(v)
            return v
        end
        return Binding.new(self)
    end
    return Binding.new(self):as(transform)
end

function Variable:__tostring()
    return "Variable<" .. tostring(self:get()) .. ">"
end

function Variable:get()
    return self._value or nil
end

function Variable:set(value)
    if value ~= self:get() then
        self._value = value
        self.variable:emit_changed()
    end
end

function Variable:start_poll()
    if self._poll ~= nil then
        return
    end

    if self.poll_fn then
        self._poll = Time.interval(self.poll_interval, function()
            self:set(self.poll_fn(self:get()))
        end)
    elseif self.poll_exec then
        self._poll = Time.interval(self.poll_interval, function()
            Process.exec_async(self.poll_exec, function(out)
                self:set(self.poll_transform(out, self:get()))
            end, function(err)
                self.variable.emit_error(err)
            end)
        end)
    end
end

function Variable:start_watch()
    if self._watch then
        return
    end

    self._watch = Process.subprocess(self.watch_exec, function(out)
        self:set(self.watch_transform(out, self:get()))
    end, function(err)
        self.variable.emit_error(err)
    end)
end

function Variable:stop_poll()
    if self._poll then
        self._poll.cancel()
    end
    self._poll = nil
end

function Variable:stop_watch()
    if self._watch then
        self._watch.kill()
    end
    self._watch = nil
end

function Variable:is_polling()
    return self._poll ~= nil
end

function Variable:is_watching()
    return self._watch ~= nil
end

function Variable:drop()
    self.variable.emit_dropped()
    Astal.Time.idle(GObject.Closure(function()
        self.variable.run_dispose()
    end))
end

---@param callback function
---@return Variable
function Variable:on_dropped(callback)
    self.variable.on_dropped = callback
    return self
end

---@param callback function
---@return Variable
function Variable:on_error(callback)
    self.err_handler = nil
    self.variable.on_eror = function(_, err)
        callback(err)
    end
    return self
end

---@param callback fun(value: any)
---@return function
function Variable:subscribe(callback)
    local id = self.variable.on_changed:connect(function()
        callback(self:get())
    end)
    return function()
        GObject.signal_handler_disconnect(self.variable, id)
    end
end

---@param interval number
---@param exec string | string[] | function
---@param transform? fun(next: any, prev: any): any
function Variable:poll(interval, exec, transform)
    if transform == nil then
        transform = function(next)
            return next
        end
    end
    self:stop_poll()
    self.poll_interval = interval
    self.poll_transform = transform

    if type(exec) == "function" then
        self.poll_fn = exec
        self.poll_exec = nil
    else
        self.poll_exec = exec
        self.poll_fn = nil
    end
    self:start_poll()
    return self
end

---@param exec string | string[]
---@param transform? fun(next: any, prev: any): any
function Variable:watch(exec, transform)
    if transform == nil then
        transform = function(next)
            return next
        end
    end
    self:stop_poll()
    self.watch_exec = exec
    self.watch_transform = transform
    self:start_watch()
    return self
end

---@param object table | table[]
---@param sigOrFn string | fun(...): any
---@param callback fun(...): any
---@return Variable
function Variable:observe(object, sigOrFn, callback)
    local f
    if type(sigOrFn) == "function" then
        f = sigOrFn
    elseif type(callback) == "function" then
        f = callback
    else
        f = function()
            return self:get()
        end
    end
    local set = function(...)
        self:set(f(...))
    end

    if type(sigOrFn) == "string" then
        object["on_" .. sigOrFn]:connect(set)
    else
        for _, obj in ipairs(object) do
            obj[1]["on_" .. obj[2]]:connect(set)
        end
    end
    return self
end

---@param deps Variable | (Binding | Variable)[]
---@param transform? fun(...): any
---@return Variable
function Variable.derive(deps, transform)
    if type(transform) == "nil" then
        transform = function(...)
            return { ... }
        end
    end

    if getmetatable(deps) == Variable then
        local var = Variable.new(transform(deps:get()))
        deps:subscribe(function(v)
            var:set(transform(v))
        end)
        return var
    end

    for i, var in ipairs(deps) do
        if getmetatable(var) == Variable then
            deps[i] = Binding.new(var)
        end
    end

    local update = function()
        local params = {}
        for _, binding in ipairs(deps) do
            table.insert(params, binding:get())
        end
        return transform(table.unpack(params))
    end

    local var = Variable.new(update())

    local unsubs = {}
    for _, b in ipairs(deps) do
        table.insert(unsubs, b:subscribe(update))
    end

    var.variable.on_dropped = function()
        for _, unsub in ipairs(unsubs) do
            var:set(unsub())
        end
    end
    return var
end

return setmetatable(Variable, {
    __call = function(_, v)
        return Variable.new(v)
    end,
})
