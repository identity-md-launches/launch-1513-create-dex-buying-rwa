import { useEffect, useRef } from "react";
import type { ReactNode } from "react";
import { ArrowUpRight, Check, Copy, X } from "lucide-react";
import { useState } from "react";
import { addressLink } from "./chain";
import type { Stock } from "./stocks";
export function StockMark({
  stock,
  small = false,
}: {
  stock: Stock;
  small?: boolean;
}) {
  return (
    <span
      aria-hidden="true"
      className={`stock-mark ${stock.color} ${small ? "small" : ""}`}
    >
      {stock.mark}
    </span>
  );
}
export function ExternalLink({
  href,
  children,
  className = "",
}: {
  href: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <a
      className={`external ${className}`}
      href={href}
      target="_blank"
      rel="noreferrer"
    >
      {children}
      <ArrowUpRight size={14} aria-hidden="true" />
      <span className="sr-only"> (opens in a new tab)</span>
    </a>
  );
}
export function AddressDisplay({
  address,
  label = "Contract",
}: {
  address: string;
  label?: string;
}) {
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");
  async function copy() {
    try {
      await navigator.clipboard.writeText(address);
      setCopied(true);
      setError("");
    } catch {
      setError("Copy unavailable. Select the address to copy it.");
    }
  }
  return (
    <div className="address-block">
      <span className="muted">{label}</span>
      <div>
        <a
          href={addressLink(address)}
          target="_blank"
          rel="noreferrer"
          className="address"
        >
          {address}
        </a>
        <button
          className="icon-button"
          onClick={() => void copy()}
          aria-label={
            copied
              ? `${label} address copied`
              : `Copy ${label.toLowerCase()} address`
          }
        >
          {copied ? <Check size={16} /> : <Copy size={16} />}
        </button>
      </div>
      {error && <span role="status">{error}</span>}
    </div>
  );
}
export function Modal({
  title,
  children,
  onClose,
  busy = false,
}: {
  title: string;
  children: ReactNode;
  onClose: () => void;
  busy?: boolean;
}) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current!;
    const active = document.activeElement as HTMLElement | null;
    dialog.showModal();
    return () => {
      dialog.close();
      active?.focus();
    };
  }, []);
  return (
    <dialog
      ref={ref}
      aria-labelledby="dialog-title"
      className="modal"
      onCancel={(e) => {
        if (busy) e.preventDefault();
        else onClose();
      }}
      onClick={(e) => {
        if (e.target === ref.current && !busy) onClose();
      }}
    >
      <div className="modal-inner">
        <div className="section-title">
          <h2 id="dialog-title">{title}</h2>
          <button
            className="icon-button"
            aria-label="Close dialog"
            disabled={busy}
            onClick={onClose}
          >
            <X size={20} />
          </button>
        </div>
        {children}
      </div>
    </dialog>
  );
}
