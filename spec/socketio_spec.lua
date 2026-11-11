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

  describe("send_with_fd / recvfd over a real unix socket", function()
    local path = ("/tmp/ldbus-test-fd-%d.sock"):format(os.time())
    local data_path = ("/tmp/ldbus-test-fd-data-%d.sock"):format(os.time())
    local server

    --- Create a connected socket pair and queue `payload` on the
    -- accepted side; returns the fd of the connecting side (reading
    -- it yields the payload).
    local function fd_with_payload(payload)
      local srv = assert(lsocket.bind(data_path))
      local c = assert(lsocket.connect(data_path))
      local a = assert(srv:accept())
      assert.truthy(a:send(payload) > 0)
      srv:close()
      return c, c:getfd()
    end

    before_each(function()
      os.remove(path)
      os.remove(data_path)
      server = assert(lsocket.bind(path))
    end)

    after_each(function()
      if server then
        server:close()
      end
      os.remove(path)
      os.remove(data_path)
    end)

    it("sends an fd with data and receives both", function()
      local sock = assert(socketio.connect({ transport = "unix", path = path }))
      local conn = assert(server:accept())
      local carrier, fd = fd_with_payload("secret")
      assert.is_true(socketio.send_with_fd(sock, "payload", fd))
      assert.truthy(lsocket.select({ conn }, 2))
      local chunk, rfd = socketio.recvfd(conn)
      assert.equals("payload", chunk)
      assert.truthy(rfd)
      local wrapped = lsocket.wrapfd(rfd)
      assert.equals("secret", wrapped:recv())
      wrapped:close()
      conn:close()
      sock:close()
      carrier:close()
    end)

    it("recvfd works on plain data (no fd attached)", function()
      local sock = assert(socketio.connect({ transport = "unix", path = path }))
      local conn = assert(server:accept())
      assert.is_true(socketio.send_all(sock, "plain"))
      assert.truthy(lsocket.select({ conn }, 2))
      local chunk, rfd = socketio.recvfd(conn)
      assert.equals("plain", chunk)
      assert.is_nil(rfd)
      conn:close()
      sock:close()
    end)

    it("recvfd returns false when nothing is ready", function()
      local sock = assert(socketio.connect({ transport = "unix", path = path }))
      local conn = assert(server:accept())
      assert.equals(false, socketio.recvfd(conn))
      conn:close()
      sock:close()
    end)
  end)
end)
