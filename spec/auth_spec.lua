local auth = require "ldbus.auth"
local mock = require "mock_socket"

describe("ldbus.auth", function()
  it("performs the EXTERNAL handshake, negotiates unix fd, returns GUID and fd_capable", function()
    local io_obj = mock({ replies = {
      "OK 0123456789abcdef0123456789abcdef\r\n",
      "AGREE_UNIX_FD\r\n",
    } })
    local guid, fd_capable, err = auth.negotiate(io_obj, "31303030")
    assert.is_nil(err)
    assert.equals("0123456789abcdef0123456789abcdef", guid)
    assert.is_true(fd_capable)
    assert.equals("\0" .. "AUTH EXTERNAL 31303030\r\n"
      .. "NEGOTIATE_UNIX_FD\r\n" .. "BEGIN\r\n", io_obj:sent())
  end)

  it("reports fd_capable=false on ERROR for NEGOTIATE_UNIX_FD", function()
    local io_obj = mock({ replies = {
      "OK abcdef0123456789abcdef0123456789\r\n",
      "ERROR not supported\r\n",
    } })
    local guid, fd_capable = auth.negotiate(io_obj, "30")
    assert.equals("abcdef0123456789abcdef0123456789", guid)
    assert.is_false(fd_capable)
  end)

  it("reports fd_capable=false on EOF during fd negotiation", function()
    local io_obj = mock({ replies = { "OK abc\r\n" } })
    local guid, fd_capable = auth.negotiate(io_obj, "30")
    assert.equals("abc", guid)
    assert.is_false(fd_capable)
  end)

  it("sends the NUL byte before the AUTH line", function()
    local io_obj = mock({ replies = { "OK abc\r\n", "AGREE_UNIX_FD\r\n" } })
    auth.negotiate(io_obj, "30")
    assert.equals("\0", io_obj.written[1]:sub(1, 1))
  end)

  it("fails on REJECTED", function()
    local io_obj = mock({ replies = { "REJECTED EXTERNAL DBUS_COOKIE_SHA1\r\n" } })
    local guid, err = auth.negotiate(io_obj, "30")
    assert.is_nil(guid)
    assert.truthy(err:find("rejected"))
  end)

  it("fails on ERROR response", function()
    local io_obj = mock({ replies = { "ERROR bad parameter\r\n" } })
    local guid, err = auth.negotiate(io_obj, "30")
    assert.is_nil(guid)
    assert.truthy(err:find("unexpected"))
  end)

  it("fails on DATA response", function()
    local io_obj = mock({ replies = { "DATA 3030\r\n" } })
    local guid, err = auth.negotiate(io_obj, "30")
    assert.is_nil(guid)
    assert.truthy(err:find("unexpected"))
  end)

  it("fails on connection close", function()
    local io_obj = mock({})
    local guid, err = auth.negotiate(io_obj, "30")
    assert.is_nil(guid)
    assert.truthy(err:find("closed"))
  end)

  it("handles replies split across chunks via the buffer", function()
    local io_obj = mock({ replies = { "OK 1234", "\r\n", "AGREE_UNIX_FD\r\n" } })
    local guid, fd_capable, err = auth.negotiate(io_obj, "30")
    assert.is_nil(err)
    assert.equals("1234", guid)
    assert.is_true(fd_capable)
  end)
end)
