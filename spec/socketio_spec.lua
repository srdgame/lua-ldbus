local socketio = require "ldbus.socketio"
local lsocket = require "lsocket"

describe("ldbus.socketio", function()
  describe("unix_path", function()
    it("converts @ abstract names to \\0 prefix", function()
      assert.equals("\0dbus-abc", socketio.unix_path("@dbus-abc"))
      assert.equals("/tmp/bus", socketio.unix_path("/tmp/bus"))
    end)
  end)

  describe("connect + send_all over a real unix socket", function()
    local path = ("/tmp/ldbus-test-%d.sock"):format(os.time())
    local server

    before_each(function()
      os.remove(path)
      server = lsocket.bind(path)
      assert.truthy(server)
    end)

    after_each(function()
      if server then
        server:close()
      end
      os.remove(path)
    end)

    it("connects and sends all bytes", function()
      local sock, err = socketio.connect({ transport = "unix", path = path })
      assert.is_nil(err)
      assert.truthy(sock)
      assert.is_true(socketio.send_all(sock, "hello world"))
      -- server accepts and reads
      local conn = server:accept()
      assert.truthy(conn)
      local data = ""
      while #data < 11 do
        local chunk = conn:recv()
        if chunk == nil then
          break
        end
        if type(chunk) == "string" then
          data = data .. chunk
        end
      end
      assert.equals("hello world", data)
      conn:close()
      sock:close()
    end)

    it("rejects unsupported transports", function()
      local sock, err = socketio.connect({ transport = "blorp" })
      assert.is_nil(sock)
      assert.truthy(err:find("unsupported"))
    end)
  end)
end)
