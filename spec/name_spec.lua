local name = require "ldbus.name"

describe("ldbus.name", function()
  it("defines RequestName flags", function()
    assert.equals(1, name.FLAG.ALLOW_REPLACEMENT)
    assert.equals(2, name.FLAG.REPLACE_EXISTING)
    assert.equals(4, name.FLAG.DO_NOT_QUEUE)
  end)

  it("defines RequestName result codes", function()
    assert.equals(1, name.RESULT.PRIMARY_OWNER)
    assert.equals(2, name.RESULT.IN_QUEUE)
    assert.equals(3, name.RESULT.EXISTS)
  end)

  it("builds match-rule style AddMatch string for signals", function()
    assert.equals("type='signal',interface='com.x.I',member='Changed'",
                  name.match_signal("com.x.I", "Changed"))
  end)
end)
