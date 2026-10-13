import { useCallback, useEffect, useRef, useState } from "react";
import type { Address, EIP1193Provider } from "viem";
import { errorMessage, loadSnapshot } from "./chain";
import type { Snapshot } from "./chain";
export type WalletOption = {
  info: { uuid: string; name: string; rdns: string };
  provider: EIP1193Provider;
};
declare global {
  interface Window {
    ethereum?: EIP1193Provider;
  }
}
export function readLocal<T>(key: string, fallback: T): T {
  try {
    return JSON.parse(localStorage.getItem(key) ?? "null") ?? fallback;
  } catch {
    return fallback;
  }
}
export function saveLocal(key: string, value: unknown) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    /* Browsing and trading do not depend on local storage. */
  }
}
export function useWallet() {
  const [options, setOptions] = useState<WalletOption[]>([]);
  const [provider, setProvider] = useState<EIP1193Provider>();
  const [account, setAccount] = useState<Address>();
  const [chainId, setChainId] = useState<number>();
  const [connecting, setConnecting] = useState(false);
  const [error, setError] = useState("");
  const [walletName, setWalletName] = useState("");
  const session = useRef(0);
  useEffect(() => {
    const announce = (event: Event) => {
      const detail = (event as CustomEvent<WalletOption>).detail;
      if (!detail?.provider?.request || !detail.info?.uuid) return;
      setOptions((old) =>
        old.some((v) => v.info.uuid === detail.info.uuid)
          ? old
          : [...old.filter((v) => v.info.uuid !== "injected"), detail],
      );
    };
    window.addEventListener("eip6963:announceProvider", announce);
    window.dispatchEvent(new Event("eip6963:requestProvider"));
    const timer = setTimeout(() => {
      if (window.ethereum)
        setOptions((old) =>
          old.length
            ? old
            : [
                {
                  info: {
                    uuid: "injected",
                    name: "Browser wallet",
                    rdns: "injected",
                  },
                  provider: window.ethereum!,
                },
              ],
        );
    }, 150);
    return () => {
      window.removeEventListener("eip6963:announceProvider", announce);
      clearTimeout(timer);
    };
  }, []);
  useEffect(() => {
    if (!provider) return;
    const accounts = (value: string[]) => {
      session.current++;
      setAccount(value[0] as Address | undefined);
    };
    const chain = (value: string) => {
      session.current++;
      setChainId(Number(value));
    };
    const disconnect = () => {
      session.current++;
      setAccount(undefined);
      setChainId(undefined);
      setProvider(undefined);
    };
    provider.on?.("accountsChanged", accounts);
    provider.on?.("chainChanged", chain);
    provider.on?.("disconnect", disconnect);
    return () => {
      provider.removeListener?.("accountsChanged", accounts);
      provider.removeListener?.("chainChanged", chain);
      provider.removeListener?.("disconnect", disconnect);
    };
  }, [provider]);
  async function connect(option: WalletOption) {
    if (connecting) return;
    setConnecting(true);
    setError("");
    try {
      const accounts = await option.provider.request({
        method: "eth_requestAccounts",
      });
      if (!accounts[0])
        throw new Error(
          "No account was shared. Open your wallet and try again.",
        );
      const chain = await option.provider.request({ method: "eth_chainId" });
      session.current++;
      setProvider(option.provider);
      setAccount(accounts[0]);
      setChainId(Number(chain));
      setWalletName(option.info.name);
      return true;
    } catch (e) {
      setError(errorMessage(e));
      return false;
    } finally {
      setConnecting(false);
    }
  }
  async function switchChain() {
    setError("");
    try {
      await provider?.request({
        method: "wallet_switchEthereumChain",
        params: [{ chainId: "0x1" }],
      });
      if (provider)
        setChainId(Number(await provider.request({ method: "eth_chainId" })));
    } catch (e) {
      setError(errorMessage(e));
    }
  }
  function disconnect() {
    session.current++;
    setAccount(undefined);
    setProvider(undefined);
    setChainId(undefined);
    setError("");
  }
  async function assertSession(expected: Address, expectedSession: number) {
    if (!provider || session.current !== expectedSession)
      throw new Error("Your wallet changed. Review this purchase again.");
    const [accounts, chain] = await Promise.all([
      provider.request({ method: "eth_accounts" }),
      provider.request({ method: "eth_chainId" }),
    ]);
    if (
      accounts[0]?.toLowerCase() !== expected.toLowerCase() ||
      Number(chain) !== 1 ||
      session.current !== expectedSession
    )
      throw new Error(
        "Your wallet or network changed. Switch to Ethereum and review again.",
      );
  }
  return {
    options,
    provider,
    account,
    chainId,
    connecting,
    error,
    walletName,
    session,
    connect,
    disconnect,
    switchChain,
    assertSession,
    setError,
  };
}
export function useMarkets() {
  const [snapshot, setSnapshot] = useState<Snapshot>();
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const running = useRef(false);
  const previousVersion = useRef<bigint | undefined>(undefined);
  const refresh = useCallback(async () => {
    if (running.current) return;
    running.current = true;
    setLoading(true);
    try {
      const next = await loadSnapshot();
      if (
        previousVersion.current !== undefined &&
        previousVersion.current !== next.version
      )
        setNotice(
          `Configuration updated to version ${next.version}. Quotes and routes have been refreshed.`,
        );
      previousVersion.current = next.version;
      setSnapshot(next);
      setError("");
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      running.current = false;
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    void refresh();
    const timer = setInterval(() => {
      if (document.visibilityState === "visible") void refresh();
    }, 30_000);
    const resume = () => {
      if (document.visibilityState === "visible") void refresh();
    };
    document.addEventListener("visibilitychange", resume);
    return () => {
      clearInterval(timer);
      document.removeEventListener("visibilitychange", resume);
    };
  }, [refresh]);
  return { snapshot, loading, error, notice, setNotice, refresh };
}
