# fluf
fluf is a lightweight service framework for managing services and their communication.

## Adding fluf
You can download the latest release of fluf as a rbxm file from https://github.com/fewkz/fluf/releases.

fluf can be added to your project via [Wally](https://wally.run/) by adding this line under dependencies.
```toml
fluf = "fewkz/fluf@0.1.1"
```

## How to use

In fluf, a service is any `LocalScript` or `Script`. fluf provides a
`onDisabled` "hook" that can be used to run code when a service script is disabled.
```lua
-- MyService.server.lua
print("Service started up")
fluf.onDisabled(script, function()
    print("Service is stopped")
end)
```

In order for `onDisabled` to work, you must register a "hook worker" that will process these hooks in another script.
```lua
local fluf = require(path.to.fluf)
fluf.registerHookWorker()
```

fluf provides ways to communicate with services via "interfaces"
An interface is a `ModuleScript` that returns a table of fluf events or state.
```lua
-- Services/BaseplateInterface.lua
local fluf = require(path.to.fluf)
local BaseplateInterface = {
    changeColor = fluf.event() :: fluf.Event<Color3>,
    instance = fluf.state() :: fluf.State<Part>,
}
return BaseplateInterface

-- Services/Baseplate.server.lua
local fluf = require(path.to.fluf)
local BaseplateInterface = require(path.to.BaseplateInterface)

local baseplate = Instance.new("Part")
baseplate.Parent = workspace

BaseplateInterface.instance.set(baseplate)
BaseplateInterface.changeColor.connect(function(newColor)
    baseplate.Color = newColor
end)

fluf.onDisabled(script, function()
    baseplate:Destroy()
    BaseplateInterface.instance.set(nil)
end)
-- some other script
local BaseplateInterface = require(path.to.BaseplateInterface)
BaseplateInterface.fire(Color3.new(1, 0, 0))
print("The baseplate's part is", BaseplateInterface.instance.get())
```
fluf events and state can be optionally typed, which will have luau typecheck it's usage.

fluf events are intended to always be used from outside the service, and fluf state
is intended to only be set by the service. However, this isn't enforced and there may
be cases where it is useful for the service to fire an event or for an outside code to set a service's state.

## Why scripts?
By having every service be a script, there are a variety of benefits.
- Scripts can have side effects that will safely be cleaned up when the script is disabled.
Since the script can't be required, you won't cause undesirable side effects when requiring a module.
- When a script is disabled, every thread or connection made in the script will be cancelled or disconnected.
This means you don't have to write tedious cleanup methods for your services.
- Starting a script by enabling it or parenting it never yields the code that started it.
This optimally schedules your services, ensuring they don't block the rest of your code.
- Scripts can't be required, which means you have to structure the communication between services
in a way that can't cause cyclic dependencies.

Scripts could still have side effects that won't be cleaned up when they're disabled, however. Especially in cases where you mutate the `DataModel`. In this case you would use the `fluf.onDisabled` hook to clean up any of these side effects. For example, removing a UI the script added to `PlayerGui`.

## Parallelization
fluf is designed to allow communication between services to work across actors. Events created by fluf will be the same across actors, and state will replicate across actors.

Hook workers will not work across actors, so you must register a hook worker in every actor.
