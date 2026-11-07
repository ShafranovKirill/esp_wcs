defmodule BastionWeb.ConnectLive do
  use BastionWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    port = Bastion.Link.port()

    addresses =
      Enum.map(Bastion.PKI.device_addresses(), fn host ->
        if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
      end)

    {:ok,
     assign(socket,
       page_title: gettext("Help"),
       addresses: addresses,
       bastion_code: Bastion.PKI.bastion_code(),
       mdns: Bastion.Discovery.method()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      current_actor={@current_actor}
      locale={@locale}
      current_path={@current_path}
    >
      <div>
        <p class="page-eyebrow">{gettext("Help")}</p>
        <h1 class="text-2xl font-semibold">{gettext("How to connect a device")}</h1>
        <p class="text-sm text-base-content/60">
          {gettext(
            "The device connects to the bastion itself over Wi-Fi; the connection is encrypted and mutually authenticated."
          )}
        </p>
      </div>

      <nav aria-label={gettext("Help topics")} class="flex flex-wrap gap-2 text-sm">
        <a
          href="#steps"
          class="rounded-lg border border-base-300 bg-base-100 px-3 py-2 hover:border-primary"
        >{gettext("How to connect")}</a>
        <a
          href="#connection-troubleshooting"
          class="rounded-lg border border-base-300 bg-base-100 px-3 py-2 hover:border-primary"
        >{gettext("Troubleshooting")}</a>
        <a
          href="#workspace-help"
          class="rounded-lg border border-base-300 bg-base-100 px-3 py-2 hover:border-primary"
        >{gettext("Console and maps")}</a>
      </nav>
      <div class="grid gap-6 lg:grid-cols-[1fr_22rem]">
        <ol class="space-y-3" id="steps">
          <.step n={1} title={gettext("Open the device setup")}>
            {gettext(
              "Hold the button on the device for 5 seconds and release it. The LED starts breathing blue."
            )}
          </.step>
          <.step n={2} title={gettext("Join the setup Wi-Fi")}>
            {gettext(
              "Connect your phone or laptop to the “ESP-WCS-XXXX” network and open https://192.168.4.1 — the browser warns about the certificate once."
            )}
          </.step>
          <.step n={3} title={gettext("Choose Bastion connection")}>
            {gettext(
              "Sign in, choose Bastion connection and connect the device to a Wi-Fi network from which this bastion is reachable."
            )}
          </.step>
          <.step n={4} title={gettext("Enter the bastion address")}>
            {gettext(
              "Copy one of the addresses on the right. bastion.local works if mDNS is available in the network, otherwise use the IP address."
            )}
            <span :if={@mdns == :off} class="text-warning" id="mdns-off">
              {gettext("mDNS is turned off on this bastion (BASTION_MDNS=off).")}
            </span>
          </.step>
          <.step n={5} title={gettext("Compare the bastion code")}>
            {gettext(
              "After “Check” the wizard shows the bastion code. It must match the code on the right — otherwise do not continue."
            )}
          </.step>
          <.step n={6} title={gettext("Approve the request")}>
            {gettext(
              "Apply the settings. The device sends a request — approve it on the Devices page after comparing the device code with the last step of the wizard."
            )}
          </.step>
        </ol>

        <aside class="space-y-4">
          <div class="card border border-base-300 bg-base-100">
            <div class="card-body gap-3 p-4">
              <h2 class="font-semibold">{gettext("Bastion address")}</h2>
              <ul class="space-y-2" id="addresses">
                <li
                  :for={{address, i} <- Enum.with_index(@addresses)}
                  class="flex items-center justify-between gap-2"
                >
                  <code class="truncate font-mono text-sm">{address}</code>
                  <.copy_button id={"copy-address-#{i}"} text={address} />
                </li>
              </ul>
              <p :if={@addresses == []} class="text-sm text-warning">
                {gettext("No network addresses found. Set BASTION_HOSTS in .env.")}
              </p>
            </div>
          </div>

          <div class="card border border-success/40 bg-base-100">
            <div class="card-body gap-2 p-4">
              <h2 class="flex items-center gap-2 font-semibold">
                <.icon name="hero-shield-check" class="size-5 text-success" /> {gettext(
                  "Bastion code"
                )}
              </h2>
              <div class="py-1">
                <.code code={@bastion_code} size="lg" id="connect-bastion-code" />
              </div>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "The device remembers the bastion by this code and will not connect to anything else."
                )}
              </p>
            </div>
          </div>

          <div class="card border border-base-300 bg-base-100">
            <div class="card-body gap-2 p-4">
              <h2 class="font-semibold">{gettext("Root certificate")}</h2>
              <p class="text-sm text-base-content/70">
                {gettext(
                  "Install it as a trusted root on your computer so the browser stops warning about this bastion."
                )}
              </p>
              <a
                href={~p"/ca.crt"}
                class="btn btn-sm"
                download="esp-wcs-bastion-ca.crt"
                id="download-ca"
              >
                <.icon name="hero-arrow-down-tray" class="size-4" /> {gettext("Download")}
              </a>
              <.link href={~p"/ca"} class="link text-sm" id="ca-instructions">
                {gettext("How to install it")}
              </.link>
            </div>
          </div>
        </aside>
      </div>
      <section id="connection-troubleshooting" class="workspace-panel space-y-4">
        <h2 class="text-lg font-semibold">{gettext("Troubleshooting")}</h2>
        <div class="grid gap-6 md:grid-cols-3">
          <div>
            <h3 class="font-medium">{gettext("No request appears")}</h3>
            <p class="mt-2 text-sm text-base-content/65">
              {gettext(
                "Check that the device Wi-Fi can reach this bastion on port 7443. A local network is sufficient; internet access is not required."
              )}
            </p>
          </div>
          <div>
            <h3 class="font-medium">{gettext("The codes do not match")}</h3>
            <p class="mt-2 text-sm text-base-content/65">
              {gettext(
                "Stop the setup and verify the bastion address. Only trust a code confirmed by your administrator."
              )}
            </p>
          </div>
          <div>
            <h3 class="font-medium">{gettext("The device lost Wi-Fi")}</h3>
            <p class="mt-2 text-sm text-base-content/65">
              {gettext(
                "Hold the device button for 5 seconds, release it and sign in to the setup interface to select the network again."
              )}
            </p>
          </div>
        </div>
      </section>
      <section id="workspace-help" class="grid gap-6 md:grid-cols-2">
        <div class="workspace-panel">
          <h2 class="font-semibold">{gettext("Console")}</h2>
          <p class="mt-3 text-sm leading-relaxed text-base-content/65">
            {gettext(
              "One operator controls the console. Read-only users can follow the output. Taking control interrupts the previous operator. Apply port settings explicitly; Backspace and device profiles are available above the terminal."
            )}
          </p>
          <p class="mt-3 text-sm leading-relaxed text-base-content/65">
            {gettext(
              "Download visible history saves the current browser buffer. The device journal records control actions, not the commands typed into the terminal."
            )}
          </p>
        </div>
        <div class="workspace-panel">
          <h2 class="font-semibold">{gettext("Folders and maps")}</h2>
          <p class="mt-3 text-sm leading-relaxed text-base-content/65">
            {gettext(
              "Use Folders and maps on the Devices page to open a location. Search the map to focus a marker. Use the wheel or + and − to zoom, 0 to fit. Escape cancels placement; Close leaves the map."
            )}
          </p>
          <p class="mt-3 text-sm leading-relaxed text-base-content/65">
            {gettext(
              "Map edits save automatically. Undo restores the previous marker position unless another operator changed it. Removing a marker leaves the device in its folder."
            )}
          </p>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :n, :integer, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp step(assigns) do
    ~H"""
    <li class="flex gap-4 rounded-box border border-base-300 bg-base-100 p-4">
      <span class="grid size-8 shrink-0 place-items-center rounded-full bg-primary/10 font-semibold text-primary">
        {@n}
      </span>
      <div>
        <h3 class="font-medium">{@title}</h3>
        <p class="mt-1 text-sm text-base-content/70">{render_slot(@inner_block)}</p>
      </div>
    </li>
    """
  end
end
