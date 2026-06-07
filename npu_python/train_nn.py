import numpy as np

np.random.seed(42)


# ── Dataset ──────────────────────────────────────────────────────

def make_moons(n_per_class=200, noise=0.12):
    n = n_per_class
    t = np.linspace(0, np.pi, n)
    x1 = (np.cos(t) - 0.5) + np.random.randn(n) * noise
    y1 = (np.sin(t) * 0.6) + np.random.randn(n) * noise
    x2 = (-np.cos(t) + 0.5) + np.random.randn(n) * noise
    y2 = (-np.sin(t) * 0.6) + np.random.randn(n) * noise
    X = np.vstack([np.column_stack([x1, y1]), np.column_stack([x2, y2])])
    y = np.array([0] * n + [1] * n)
    return X.astype(np.float64), y


# ── Activations ──────────────────────────────────────────────────

def relu(x):
    return np.maximum(0.0, x)


def relu_grad(x):
    return (x > 0.0).astype(np.float64)


def softmax(x):
    xm = x - x.max(axis=0, keepdims=True)
    e = np.exp(xm)
    return e / (e.sum(axis=0, keepdims=True) + 1e-15)


# ── Network ──────────────────────────────────────────────────────

class Net:
    def __init__(self, lr=0.05):
        K = 1.0  # gain
        self.W1 = np.random.randn(4, 4) * K / 2
        self.b1 = np.zeros(4)
        self.W2 = np.random.randn(4, 4) * K / 2
        self.b2 = np.zeros(4)
        self.W3 = np.random.randn(4, 2) * K / 2
        self.b3 = np.zeros(2)
        self.lr = lr

    def forward(self, X, cache=False):
        N = X.shape[1]
        xp = np.vstack([X, np.ones((1, N)), np.zeros((1, N))])
        z1 = self.W1 @ xp + self.b1[:, None]
        a1 = relu(z1)
        z2 = self.W2 @ a1 + self.b2[:, None]
        a2 = relu(z2)
        z3 = self.W3.T @ a2 + self.b3[:, None]
        out = softmax(z3)
        if cache:
            return out, (xp, z1, a1, z2, a2)
        return out

    def backward(self, X, y_onehot, cache):
        xp, z1, a1, z2, a2 = cache
        N = X.shape[1]
        out = softmax(self.W3.T @ a2 + self.b3[:, None])

        d3 = out - y_onehot
        dW3 = a2 @ d3.T
        db3 = d3.sum(axis=1)

        da2 = self.W3 @ d3
        dz2 = da2 * relu_grad(z2)
        dW2 = a1 @ dz2.T
        db2 = dz2.sum(axis=1)

        da1 = self.W2 @ dz2
        dz1 = da1 * relu_grad(z1)
        dW1 = xp @ dz1.T
        db1 = dz1.sum(axis=1)

        # Clip gradients
        for g in [dW1, db1, dW2, db2, dW3, db3]:
            np.clip(g, -5.0, 5.0, out=g)

        self.W3 -= self.lr * dW3 / N
        self.b3 -= self.lr * db3 / N
        self.W2 -= self.lr * dW2 / N
        self.b2 -= self.lr * db2 / N
        self.W1 -= self.lr * dW1 / N
        self.b1 -= self.lr * db1 / N

    def accuracy(self, X, y):
        out = self.forward(X.T)
        preds = np.argmax(out, axis=0)
        return np.mean(preds == y)


# ── Train ────────────────────────────────────────────────────────

def train(epochs=8000):
    X, y = make_moons(200, noise=0.12)
    mean, std = X.mean(axis=0), X.std(axis=0)
    X = (X - mean) / std

    y_onehot = np.zeros((2, X.shape[0]))
    y_onehot[0, y == 0] = 1
    y_onehot[1, y == 1] = 1

    net = Net(lr=0.05)
    best_acc = 0.0
    best_params = None

    for ep in range(epochs):
        # Full-batch gradient descent
        out, cache = net.forward(X.T, cache=True)
        net.backward(X.T, y_onehot, cache)

        if ep % 500 == 0 or ep == epochs - 1:
            acc = net.accuracy(X, y)
            loss = -np.mean(np.sum(y_onehot * np.log(out + 1e-15), axis=0))
            print(f'epoch {ep:4d}  loss={loss:.4f}  acc={acc:.3f}')
            if acc > best_acc:
                best_acc = acc
                best_params = (net.W1.copy(), net.b1.copy(),
                               net.W2.copy(), net.b2.copy(),
                               net.W3.copy(), net.b3.copy())

    acc = net.accuracy(X, y)
    print(f'\nFinal accuracy: {acc:.3f}')

    # Restore best params if they exist
    if best_params is not None:
        net.W1, net.b1, net.W2, net.b2, net.W3, net.b3 = best_params
        print(f'Best accuracy: {best_acc:.3f}')

    return net, mean, std


if __name__ == '__main__':
    net, mean, std = train(epochs=8000)
    np.savez('nn_model.npz',
             W1=net.W1, b1=net.b1,
             W2=net.W2, b2=net.b2,
             W3=net.W3, b3=net.b3,
             mean=mean, std=std)
    print('Saved model to nn_model.npz')

    # Quick verification
    from verilog_backend import verilog_matmul
    q = 256

    def npu_forward(x, y):
        xp = np.array([x, y, 1.0, 0.0])
        B = np.zeros((4, 4))
        B[:, 0] = xp
        Aq = np.clip(np.round(net.W1 * q), -32768, 32767).astype(np.int32)
        Bq = np.clip(np.round(B * q), -32768, 32767).astype(np.int32)
        Cq = verilog_matmul(Aq, Bq)
        h1 = np.maximum(0, Cq[:, 0] / (q * q) + net.b1)

        B[:, 0] = h1
        Aq = np.clip(np.round(net.W2 * q), -32768, 32767).astype(np.int32)
        Bq = np.clip(np.round(B * q), -32768, 32767).astype(np.int32)
        Cq = verilog_matmul(Aq, Bq)
        h2 = np.maximum(0, Cq[:, 0] / (q * q) + net.b2)

        W3T = np.zeros((4, 4))
        W3T[:2, :] = net.W3.T
        B[:, 0] = h2
        Aq = np.clip(np.round(W3T * q), -32768, 32767).astype(np.int32)
        Bq = np.clip(np.round(B * q), -32768, 32767).astype(np.int32)
        Cq = verilog_matmul(Aq, Bq)
        logits = Cq[:2, 0] / (q * q) + net.b3
        e = np.exp(logits - logits.max())
        return e / e.sum()

    Xt, yt = make_moons(50, noise=0.0)
    Xt = (Xt - mean) / std
    correct = 0
    for i in range(len(Xt)):
        p = npu_forward(Xt[i, 0], Xt[i, 1])
        if np.argmax(p) == yt[i]:
            correct += 1
    print(f'NPU inference accuracy: {correct / len(Xt):.3f}')
