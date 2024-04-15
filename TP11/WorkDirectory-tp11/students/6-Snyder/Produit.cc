#include <6-Snyder/Produit.h>
#include <OPP/MPI/OPP_MPI.h>

#include <DistributedBlockMatrix.h>
#include <memory>
#include <thread>

namespace {

  void transposition(const OPP::MPI::Torus &torus, float *buffer, const int L) {
    using Direction = OPP::MPI::Torus::Direction;

    const int x = torus.getRowRing().getRank();
    const int y = torus.getColumnRing().getRank();

    auto *buffer1 = new float[L];
    auto *buffer2 = new float[L];

    if (x < y) {
      torus.Send(buffer, L, MPI_FLOAT, Direction::EAST);

      for (int i = 0; i < x; ++i) {
        torus.Recv(buffer1, L, MPI_FLOAT, Direction::WEST);
        torus.Send(buffer1, L, MPI_FLOAT, Direction::EAST);
      }
      for (int i = 0; i < x; ++i) {
        torus.Recv(buffer2, L, MPI_FLOAT, Direction::EAST);
        torus.Send(buffer2, L, MPI_FLOAT, Direction::WEST);
      }

      torus.Recv(buffer, L, MPI_FLOAT, Direction::EAST);
    } else if (x > y) {
      torus.Send(buffer, L, MPI_FLOAT, Direction::SOUTH);

      for (int i = 0; i < y; ++i) {
        torus.Recv(buffer1, L, MPI_FLOAT, Direction::NORTH);
        torus.Send(buffer1, L, MPI_FLOAT, Direction::SOUTH);
      }
      for (int i = 0; i < y; ++i) {
        torus.Recv(buffer2, L, MPI_FLOAT, Direction::SOUTH);
        torus.Send(buffer2, L, MPI_FLOAT, Direction::NORTH);
      }

      torus.Recv(buffer, L, MPI_FLOAT, Direction::SOUTH);
    } else {
      for (int i = 0; i < x; ++i) {
        torus.Recv(buffer1, L, MPI_FLOAT, Direction::NORTH);
        torus.Send(buffer1, L, MPI_FLOAT, Direction::WEST);
      }
      for (int i = 0; i < x; ++i) {
        torus.Recv(buffer2, L, MPI_FLOAT, Direction::WEST);
        torus.Send(buffer2, L, MPI_FLOAT, Direction::NORTH);
      }
    }

    delete[] buffer1;
    delete[] buffer2;
  }

  void BroadcastRowAdd(const OPP::MPI::Torus &torus, const int x, const int k,
                       float *src, float *dest, const int L, const int r) {
    if (torus.getColumnRing().getRank() == x) {
      using Direction = OPP::MPI::Torus::Direction;

      if (torus.getRowRing().getRank() == k) {
        for (int i = 0; i < r; ++i) {
          torus.Send(&src[i * L / r], L / r, MPI_FLOAT, Direction::EAST);
        }
        for (int i = 0; i < r; ++i) {
          torus.Recv(&dest[i * L / r], L / r, MPI_FLOAT, Direction::WEST);
          for (int j = i * L / r; j < (i + 1) * L / r; ++j) {
            dest[i * L / r + i] += dest[j];
          }
        }
      } else {
        torus.Recv(dest, L / r, MPI_FLOAT, Direction::WEST);
        for (int i = 0; i < r - 1; ++i) {
          for (int j = i * L / r; j < (i + 1) * L / r; ++j) {
            src[j] += dest[j];
          }
          MPI_Request request =
              torus.AsyncSend(&src[i * L / r], L / r, MPI_FLOAT, Direction::EAST);
          torus.Recv(&dest[(i + 1) * L / r], L / r, MPI_FLOAT, Direction::WEST);
          MPI_Wait(&request, MPI_STATUS_IGNORE);
        }
        for (int j = (r - 1) * L / r; j < r * L / r; ++j) {
          src[j] += dest[j];
        }
        torus.Send(&src[(r - 1) * L / r], L / r, MPI_FLOAT, Direction::EAST);
      }
    }
  }

  void RotationVerticale(const OPP::MPI::Torus &torus, float *buffer,
                         const int L) {
    torus.Send(buffer, L, MPI_FLOAT, OPP::MPI::Torus::Direction::NORTH);
    torus.Recv(buffer, L, MPI_FLOAT, OPP::MPI::Torus::Direction::SOUTH);
  }

  void init(const DistributedBlockMatrix &A, const DistributedBlockMatrix &B,
            DistributedBlockMatrix &C, float *bufferA, float *bufferB,
            const int r) {
    int A_start = A.Start();
    int B_start = B.Start();
    int C_start = C.Start();

    for (int i = 0; i < r; ++i) {
      for (int j = 0; j < r; ++j) {
        bufferA[i * r + j] = A[i + A_start][j + A[i + A_start].Start()];
        bufferB[i * r + j] = B[j + B_start][i + B[j + B_start].Start()];
        C[i + C_start][j + C[i + C_start].Start()] = 0.0f;
      }
    }
  }

} // namespace

void Produit(const OPP::MPI::Torus &torus, const DistributedBlockMatrix &A,
             const DistributedBlockMatrix &B, DistributedBlockMatrix &C) {
  const int n = sqrt(torus.getCommunicator().size);
  const int x = torus.getColumnRing().getRank();
  const int y = torus.getRowRing().getRank();
  const int r = C.End() - C.Start();
  const int L = r * r;

  auto *bufferA = new float[L];
  auto *bufferB = new float[L];
  auto *send_bufferC = new float[L];
  auto *recv_bufferC = new float[L];

  init(A, B, C, bufferA, bufferB, r);

  transposition(torus, bufferB, L);

  for (int i = 0; i < L; ++i) {
    send_bufferC[i] = bufferA[i] * bufferB[i];
  }

  for (int k = 0; k < n; ++k) {
    int diag = (x + k) % n;
    BroadcastRowAdd(torus, x, diag, send_bufferC, recv_bufferC, L, r);
    if (diag == y) {
      for (int i = 0; i < r; ++i) {
        for (int j = 0; j < r; ++j) {
          C[i + C.Start()][j + C[i + C.Start()].Start()] = recv_bufferC[i * r + j];
        }
      }
    }

    RotationVerticale(torus, bufferB, L);

    for (int i = 0; i < L; ++i) {
      send_bufferC[i] = bufferA[i] * bufferB[i];
    }
  }

  delete[] bufferA;
  delete[] bufferB;
  delete[] send_bufferC;
  delete[] recv_bufferC;
}
/**********************************/
/*   AL NATOUR MAZEN, M1 Info CL  */
/**********************************/